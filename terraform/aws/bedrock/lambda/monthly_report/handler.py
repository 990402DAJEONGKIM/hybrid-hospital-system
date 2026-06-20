"""
Monthly Report Lambda
S3 chunks를 읽어 Claude로 월간 리포트 작성 후 SES로 HTML 이메일 + PDF 첨부 발송
"""
import io
import json
import os
import re
import smtplib
from datetime import date, timedelta
from email import encoders
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

import boto3

BEDROCK_REGION    = os.environ["BEDROCK_REGION"]
STORAGE_BUCKET    = os.environ["STORAGE_BUCKET"]
ADMIN_EMAIL       = os.environ["ADMIN_EMAIL"]
FROM_EMAIL        = os.environ.get("FROM_EMAIL", ADMIN_EMAIL)
SES_REGION        = os.environ["SES_REGION"]
ANNUAL_BUDGET_KRW = int(os.environ.get("ANNUAL_BUDGET_KRW", "30000000"))
SSM_EXIM_API_KEY  = os.environ.get("SSM_EXIM_API_KEY", "")
RAW_PREFIX        = "cost/cost-raw"
EMBED_MODEL_ID    = "amazon.titan-embed-text-v2:0"
_RATE_CACHE_PARAM = "/mzclinic/cost/exim/usd-krw-cache"
_rate_cache: dict = {}

S3      = boto3.client("s3")
SSM     = boto3.client("ssm")
BEDROCK = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)
SES     = boto3.client("ses", region_name=SES_REGION)

MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"


# ── 환율 ──────────────────────────────────────────────────────────────────

def _get_usd_krw_rate() -> float:
    today_str = date.today().isoformat()
    if _rate_cache.get("date") == today_str:
        return _rate_cache["rate"]
    try:
        val = SSM.get_parameter(Name=_RATE_CACHE_PARAM)["Parameter"]["Value"]
        rate_str, cached_date = val.rsplit(":", 1)
        if cached_date == today_str:
            rate = float(rate_str)
            _rate_cache.update({"rate": rate, "date": today_str})
            return rate
    except Exception:
        pass
    if not SSM_EXIM_API_KEY:
        return 1400.0
    try:
        api_key = SSM.get_parameter(Name=SSM_EXIM_API_KEY, WithDecryption=True)["Parameter"]["Value"]
    except Exception:
        return 1400.0
    import urllib.request
    today = date.today()
    for delta in range(7):
        d = today - timedelta(days=delta)
        url = (
            "https://oapi.koreaexim.go.kr/site/program/financial/exchangeJSON"
            f"?authkey={api_key}&searchdate={d.strftime('%Y%m%d')}&data=AP01"
        )
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                items = json.loads(resp.read())
            usd = next((x for x in items if x.get("cur_unit") == "USD"), None)
            if usd:
                rate = float(usd["deal_bas_r"].replace(",", ""))
                try:
                    SSM.put_parameter(Name=_RATE_CACHE_PARAM, Value=f"{rate}:{today_str}", Type="String", Overwrite=True)
                except Exception:
                    pass
                _rate_cache.update({"rate": rate, "date": today_str})
                return rate
        except Exception:
            continue
    return 1400.0


# ── cost-raw/ 직접 읽기 ────────────────────────────────────────────────────

def _read_aws(year: str, month: str) -> list[dict]:
    import csv as csv_mod
    key = f"{RAW_PREFIX}/aws/{year}/{month}/aws_cost.csv"
    try:
        body = S3.get_object(Bucket=STORAGE_BUCKET, Key=key)["Body"].read().decode("utf-8")
        return list(csv_mod.DictReader(io.StringIO(body)))
    except Exception:
        return []


def _read_gcp(year: str, month: str) -> list[dict]:
    import csv as csv_mod
    key = f"{RAW_PREFIX}/gcp/{year}/{month}/gcp_cost.csv"
    try:
        body = S3.get_object(Bucket=STORAGE_BUCKET, Key=key)["Body"].read().decode("utf-8")
        return list(csv_mod.DictReader(io.StringIO(body)))
    except Exception:
        return []


def _read_onprem(year: str, month: str) -> dict:
    key = f"{RAW_PREFIX}/onprem/{year}/{month}/onprem_cost.json"
    try:
        return json.loads(S3.get_object(Bucket=STORAGE_BUCKET, Key=key)["Body"].read())
    except Exception:
        return {}


def _load_raw_costs() -> str:
    usd_to_krw = _get_usd_krw_rate()
    today = date.today()
    texts = []

    # 전전월, 전월, 당월 순서로 처리
    for delta in [2, 1, 0]:
        first = today.replace(day=1)
        for _ in range(delta):
            first = (first - timedelta(days=1)).replace(day=1)
        year  = str(first.year)
        month = f"{first.month:02d}"
        label = {2: "전전월 (비교 기준)", 1: "전월 (보고 대상)", 0: "당월 (집계 중)"}[delta]

        lines = [f"[{year}년 {int(month)}월 비용 — {label}]"]

        # AWS
        aws_rows = _read_aws(year, month)
        if aws_rows:
            aws_by_svc: dict[str, float] = {}
            for r in aws_rows:
                name = r.get("ProductName", "")
                if name:
                    aws_by_svc[name] = aws_by_svc.get(name, 0) + float(r.get("UnblendedCost", 0))
            aws_total = sum(aws_by_svc.values()) * usd_to_krw
            lines.append(f"AWS 합계: {round(aws_total):,}원")
            for svc, usd in sorted(aws_by_svc.items(), key=lambda x: -x[1])[:5]:
                lines.append(f"  {svc}: {round(usd * usd_to_krw):,}원")
        else:
            lines.append("AWS: 데이터 없음")
            aws_total = 0

        # GCP
        gcp_rows = _read_gcp(year, month)
        if gcp_rows:
            def _to_krw(r: dict) -> float:
                c = float(r.get("total_cost", 0))
                return c if r.get("currency") == "KRW" else c * usd_to_krw
            gcp_total = sum(_to_krw(r) for r in gcp_rows)
            lines.append(f"GCP 합계: {round(gcp_total):,}원")
            for r in sorted(gcp_rows, key=lambda x: -float(x.get("total_cost", 0)))[:5]:
                lines.append(f"  {r.get('service', '')}: {round(_to_krw(r)):,}원")
        else:
            lines.append("GCP: 데이터 없음")
            gcp_total = 0

        # 온프레미스
        onprem = _read_onprem(year, month)
        onprem_total = onprem.get("total_krw", 0)
        if onprem_total:
            lines.append(f"온프레미스 합계: {onprem_total:,}원")
        else:
            lines.append("온프레미스: 데이터 없음")

        total = aws_total + gcp_total + onprem_total
        lines.append(f"전체 합계: {round(total):,}원")

        # 예산 집행률 (당월 기준)
        if delta == 0 and ANNUAL_BUDGET_KRW:
            pct = round(total / ANNUAL_BUDGET_KRW * 100, 1)
            lines.append(f"연간 예산({ANNUAL_BUDGET_KRW:,}원) 대비 집행률: {pct}%")

        texts.append("\n".join(lines))

    return "\n\n---\n\n".join(texts)


# ── DIY 벡터 RAG ──────────────────────────────────────────────────────────

def _embed(text: str) -> list[float]:
    resp = BEDROCK.invoke_model(
        modelId=EMBED_MODEL_ID,
        body=json.dumps({"inputText": text[:8000], "dimensions": 512, "normalize": True}),
    )
    return json.loads(resp["body"].read())["embedding"]


def _save_vectors(year: str, month: str, report_text: str):
    sections = re.split(r"\n(?=## )", report_text.strip())
    chunks = []
    for i, section in enumerate(sections):
        section = section.strip()
        if not section:
            continue
        chunks.append({
            "id":        f"{year}-{month}-{i}",
            "year":      year,
            "month":     month,
            "text":      section,
            "embedding": _embed(section),
        })
    s3_key = f"cost/cost-vectors/{year}/{month}/vectors.json"
    S3.put_object(
        Bucket=STORAGE_BUCKET,
        Key=s3_key,
        Body=json.dumps(chunks, ensure_ascii=False),
        ContentType="application/json",
    )
    print(f"Vectors saved: {s3_key} ({len(chunks)} chunks)")


# ── 날짜 유틸 ──────────────────────────────────────────────────────────────

def _get_target_month() -> tuple[str, str]:
    today = date.today()
    first = today.replace(day=1)
    last_month = first - timedelta(days=1)
    return str(last_month.year), f"{last_month.month:02d}"


def _is_third_monday() -> bool:
    today = date.today()
    return today.weekday() == 0 and 15 <= today.day <= 21


# ── Bedrock 리포트 생성 ────────────────────────────────────────────────────

def _generate_report(year: str, month: str, cost_context: str) -> str:
    prompt = f"""당신은 IT 인프라 비용 분석 전문가입니다.
아래 데이터를 바탕으로 {year}년 {int(month)}월 IT 인프라 비용 현황 보고서를 작성하세요.

[비용 데이터]
{cost_context}

다음 형식을 반드시 준수하세요:

## 1. 이번 달 비용 요약

| 구분 | {int(month)}월 비용 | 전월 대비 | 비율 |
|------|---------|---------|------|
| **AWS** | X,XXX,XXX원 | +X.X% | X.X% |
| **GCP** | XX,XXX,XXX원 | +X.X% | XX.X% |
| **온프레미스** | XXX,XXX원 | +X.X% | X.X% |
| **합계** | XX,XXX,XXX원 | +X.X% | 100.0% |

## 2. 서비스별 주요 비용

AWS와 GCP의 상위 3개 서비스를 각각 표로 작성하세요.

## 3. 전월 대비 분석

증감 원인을 2~3문장으로 간결하게 작성하세요.

## 4. 예산 현황

연간 예산 대비 집행률을 1~2문장으로 작성하세요.

## 5. 이상 지표

전월 대비 30% 이상 증가 항목을 나열하세요. 없으면 "이상 지표 없음"으로 기재하세요.

## 6. 비용 절감 권고사항

실행 가능한 권고사항 2~3개를 간결하게 작성하세요.

숫자는 반드시 한국 원화(원) 단위로 작성하고, 표는 마크다운 표 형식을 사용하세요."""

    resp = BEDROCK.invoke_model(
        modelId=MODEL_ID,
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 2048,
            "messages": [{"role": "user", "content": prompt}],
        }),
    )
    return json.loads(resp["body"].read())["content"][0]["text"]


# ── 마크다운 → HTML 변환 ───────────────────────────────────────────────────

def _fmt_inline(text: str) -> str:
    """굵은 글씨, 이탤릭 처리"""
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\*(.+?)\*",     r"<em>\1</em>",          text)
    return text


def _md_to_html(text: str) -> str:
    lines = text.splitlines()
    out = []
    in_table = False
    header_done = False
    in_list = False

    for line in lines:
        stripped = line.strip()

        # 표 행
        if stripped.startswith("|") and stripped.endswith("|"):
            # 구분선 (|---|---| 형태) 은 건너뜀
            if re.match(r"^[\|\s\-:]+$", stripped):
                header_done = True
                continue
            if not in_table:
                in_table = True
                header_done = False
                if in_list:
                    out.append("</ul>")
                    in_list = False
                out.append('<table class="report-table">')
            cells = [c.strip() for c in stripped.split("|")[1:-1]]
            tag = "th" if not header_done else "td"
            row = "".join(f"<{tag}>{_fmt_inline(c)}</{tag}>" for c in cells)
            out.append(f"<tr>{row}</tr>")
            continue

        # 표 종료
        if in_table:
            out.append("</table>")
            in_table = False
            header_done = False

        # 제목
        if stripped.startswith("### "):
            if in_list: out.append("</ul>"); in_list = False
            out.append(f'<h4 class="rh4">{_fmt_inline(stripped[4:])}</h4>')
        elif stripped.startswith("## "):
            if in_list: out.append("</ul>"); in_list = False
            out.append(f'<h3 class="rh3">{_fmt_inline(stripped[3:])}</h3>')
        elif stripped.startswith("# "):
            if in_list: out.append("</ul>"); in_list = False
            out.append(f'<h2 class="rh2">{_fmt_inline(stripped[2:])}</h2>')
        # 목록
        elif stripped.startswith("- ") or stripped.startswith("* "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{_fmt_inline(stripped[2:])}</li>")
        # 빈 줄
        elif not stripped:
            if in_list:
                out.append("</ul>")
                in_list = False
            out.append("<br>")
        # 일반 문단
        else:
            if in_list:
                out.append("</ul>")
                in_list = False
            out.append(f"<p>{_fmt_inline(stripped)}</p>")

    if in_table: out.append("</table>")
    if in_list:  out.append("</ul>")
    return "\n".join(out)


# ── HTML 이메일 템플릿 ─────────────────────────────────────────────────────

def _build_html(year: str, month: str, report_text: str) -> str:
    today = date.today().strftime("%Y년 %m월 %d일")
    body_html = _md_to_html(report_text)

    return f"""<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  * {{ box-sizing:border-box; margin:0; padding:0; }}
  body {{ font-family:'Malgun Gothic','맑은 고딕',Arial,sans-serif; background:#f0f2f5; color:#333; }}
  .wrap {{ max-width:680px; margin:24px auto; background:#fff; border:1px solid #dde2ea; border-radius:4px; overflow:hidden; }}
  .top-bar {{ background:#1a3a5c; padding:6px 24px; }}
  .top-bar span {{ color:#a8c4e0; font-size:11px; letter-spacing:1px; }}
  .header {{ background:#1a3a5c; padding:28px 32px 24px; border-bottom:3px solid #e8a020; }}
  .header h1 {{ color:#fff; font-size:20px; font-weight:700; margin-bottom:4px; }}
  .header p {{ color:#a8c4e0; font-size:13px; }}
  .meta {{ background:#f7f9fc; border-bottom:1px solid #dde2ea; padding:14px 32px; }}
  .meta table {{ width:100%; border-collapse:collapse; font-size:12px; }}
  .meta td {{ padding:3px 8px 3px 0; color:#555; }}
  .meta td:first-child {{ color:#888; width:90px; white-space:nowrap; }}
  .notice {{ margin:20px 32px 0; padding:12px 16px; background:#fff8ec; border-left:4px solid #e8a020; border-radius:2px; font-size:12px; color:#7a5000; }}
  .body {{ padding:24px 32px 28px; font-size:13px; line-height:1.9; color:#333; }}
  .body .rh2 {{ color:#1a3a5c; font-size:16px; margin:24px 0 8px; }}
  .body .rh3 {{ color:#1a3a5c; font-size:14px; font-weight:700; margin:20px 0 6px; padding-bottom:4px; border-bottom:1px solid #e8edf3; }}
  .body .rh4 {{ color:#444; font-size:13px; font-weight:700; margin:14px 0 4px; }}
  .body p {{ margin-bottom:6px; }}
  .body ul {{ margin:6px 0 10px 20px; }}
  .body li {{ margin-bottom:3px; }}
  .report-table {{ width:100%; border-collapse:collapse; font-size:12px; margin:12px 0 16px; }}
  .report-table th {{ background:#1a3a5c; color:#fff; padding:8px 10px; text-align:left; font-weight:600; }}
  .report-table td {{ padding:7px 10px; border-bottom:1px solid #eaecf0; }}
  .report-table tr:nth-child(even) td {{ background:#f7f9fc; }}
  .report-table tr:last-child td {{ font-weight:700; background:#eef2f7; }}
  .divider {{ height:1px; background:#dde2ea; margin:0 32px; }}
  .footer {{ padding:18px 32px; font-size:11px; color:#999; line-height:1.7; }}
  .footer a {{ color:#1a3a5c; text-decoration:none; }}
  .attach-note {{ margin:12px 32px 0; padding:10px 14px; background:#f0f7ff; border:1px solid #cce0ff; border-radius:3px; font-size:11px; color:#1a3a5c; }}
</style>
</head>
<body>
<div class="wrap">
  <div class="top-bar"><span>MZ Clinic · AI Cost Analysis System · Powered by AWS Bedrock</span></div>

  <div class="header">
    <h1>IT 인프라 운영비용 월간 현황 보고</h1>
    <p>{year}년 {int(month)}월 기준 · AWS / GCP / On-premises</p>
  </div>

  <div class="meta">
    <table>
      <tr><td>발 신</td><td>MZ클리닉 AI 비용분석 시스템 (Powered by AWS Bedrock)</td></tr>
      <tr><td>수 신</td><td>관리자</td></tr>
      <tr><td>기준 월</td><td>{year}년 {int(month)}월</td></tr>
      <tr><td>발송 일시</td><td>{today} (자동 발송)</td></tr>
    </table>
  </div>

  <div class="notice">
    본 보고서는 AWS Bedrock AI가 자동 분석·생성한 월간 비용 현황입니다.
    수치 이상 발견 시 담당자가 직접 확인하시기 바랍니다.
  </div>

  <div class="attach-note">
    📎 상세 보고서 PDF가 첨부되어 있습니다. (infra_report_{year}_{month}.pdf)
  </div>

  <div class="body">{body_html}</div>

  <div class="divider"></div>
  <div class="footer">
    본 메일은 발신 전용입니다. 회신하지 마시기 바랍니다.<br>
    MZ클리닉 AI 비용분석 시스템 · <a href="mailto:no-reply@mzclinic.cloud">no-reply@mzclinic.cloud</a><br>
    © {year} MZ Clinic. All rights reserved.
  </div>
</div>
</body>
</html>"""


# ── PDF 생성 (reportlab) ───────────────────────────────────────────────────

def _generate_pdf(year: str, month: str, report_text: str) -> bytes:
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
    from reportlab.lib.units import cm
    from reportlab.lib import colors
    from reportlab.platypus import (
        Paragraph, SimpleDocTemplate, Spacer,
        Table, TableStyle, HRFlowable,
    )
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont

    # 한글 폰트 등록 (Lambda 패키지에 포함된 NanumGothic)
    font_dir = os.path.dirname(os.path.abspath(__file__))
    pdfmetrics.registerFont(TTFont("NanumGothic",      os.path.join(font_dir, "NanumGothic.ttf")))
    pdfmetrics.registerFont(TTFont("NanumGothic-Bold", os.path.join(font_dir, "NanumGothic-Bold.ttf")))

    buf = io.BytesIO()
    doc = SimpleDocTemplate(
        buf, pagesize=A4,
        topMargin=2*cm, bottomMargin=2*cm,
        leftMargin=2.5*cm, rightMargin=2.5*cm,
    )

    styles = getSampleStyleSheet()
    title_style = ParagraphStyle("title",
        fontSize=16, fontName="NanumGothic-Bold",
        textColor=colors.HexColor("#1a3a5c"), spaceAfter=6)
    sub_style = ParagraphStyle("sub",
        fontSize=10, fontName="NanumGothic",
        textColor=colors.HexColor("#555555"), spaceAfter=14)
    h2_style = ParagraphStyle("h2",
        fontSize=13, fontName="NanumGothic-Bold",
        textColor=colors.HexColor("#1a3a5c"),
        spaceBefore=14, spaceAfter=6)
    h3_style = ParagraphStyle("h3",
        fontSize=11, fontName="NanumGothic-Bold",
        textColor=colors.HexColor("#333333"),
        spaceBefore=10, spaceAfter=4)
    body_style = ParagraphStyle("body",
        fontSize=10, fontName="NanumGothic",
        textColor=colors.HexColor("#333333"),
        leading=16, spaceAfter=4)
    small_style = ParagraphStyle("small",
        fontSize=8, fontName="NanumGothic",
        textColor=colors.HexColor("#888888"), spaceAfter=2)

    story = []

    # 헤더
    story.append(Paragraph(f"IT 인프라 운영비용 월간 현황 보고", title_style))
    story.append(Paragraph(f"{year}년 {int(month)}월 기준  |  AWS · GCP · On-premises", sub_style))
    story.append(HRFlowable(width="100%", thickness=2, color=colors.HexColor("#e8a020"), spaceAfter=8))
    today_str = date.today().strftime("%Y년 %m월 %d일")
    meta = [
        ["발  신", "MZ클리닉 AI 비용분석 시스템 (Powered by AWS Bedrock)"],
        ["수  신", "관리자"],
        ["기준 월", f"{year}년 {int(month)}월"],
        ["발송 일시", f"{today_str} (자동 발송)"],
    ]
    meta_table = Table(meta, colWidths=[3*cm, 12*cm])
    meta_table.setStyle(TableStyle([
        ("FONTNAME",    (0,0),(-1,-1), "NanumGothic"),
        ("FONTSIZE",    (0,0),(-1,-1), 9),
        ("TEXTCOLOR",   (0,0),(0,-1),  colors.HexColor("#888888")),
        ("TEXTCOLOR",   (1,0),(1,-1),  colors.HexColor("#333333")),
        ("TOPPADDING",  (0,0),(-1,-1), 3),
        ("BOTTOMPADDING",(0,0),(-1,-1), 3),
    ]))
    story.append(meta_table)
    story.append(Spacer(1, 0.4*cm))
    story.append(HRFlowable(width="100%", thickness=0.5, color=colors.HexColor("#dde2ea"), spaceAfter=12))

    # 본문 파싱 (마크다운 → reportlab)
    lines = report_text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()

        if line.startswith("## "):
            story.append(Paragraph(line[3:], h2_style))
        elif line.startswith("# "):
            story.append(Paragraph(line[2:], h2_style))
        elif line.startswith("### "):
            story.append(Paragraph(line[4:], h3_style))
        elif line.startswith("|") and line.endswith("|"):
            # 표 수집
            tbl_lines = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                tbl_lines.append(lines[i].strip())
                i += 1
            tbl_lines = [l for l in tbl_lines if not re.match(r"^[\|\s\-:]+$", l)]
            tbl_data = []
            for tl in tbl_lines:
                cells = [re.sub(r"\*\*(.+?)\*\*", r"\1", c.strip()) for c in tl.split("|")[1:-1]]
                tbl_data.append(cells)
            if tbl_data:
                col_count = len(tbl_data[0])
                col_w = 14.5 * cm / col_count
                pdf_table = Table(tbl_data, colWidths=[col_w]*col_count)
                pdf_table.setStyle(TableStyle([
                    ("BACKGROUND",    (0,0),(-1,0),  colors.HexColor("#1a3a5c")),
                    ("TEXTCOLOR",     (0,0),(-1,0),  colors.white),
                    ("FONTNAME",      (0,0),(-1,0),  "NanumGothic-Bold"),
                    ("FONTNAME",      (0,1),(-1,-1), "NanumGothic"),
                    ("FONTSIZE",      (0,0),(-1,-1), 9),
                    ("ROWBACKGROUNDS",(0,1),(-1,-1), [colors.white, colors.HexColor("#f7f9fc")]),
                    ("GRID",          (0,0),(-1,-1), 0.3, colors.HexColor("#dde2ea")),
                    ("TOPPADDING",    (0,0),(-1,-1), 5),
                    ("BOTTOMPADDING", (0,0),(-1,-1), 5),
                    ("LEFTPADDING",   (0,0),(-1,-1), 6),
                    ("FONTNAME",      (0,-1),(-1,-1), "NanumGothic-Bold"),
                    ("BACKGROUND",    (0,-1),(-1,-1), colors.HexColor("#eef2f7")),
                ]))
                story.append(pdf_table)
                story.append(Spacer(1, 0.3*cm))
            continue
        elif line.startswith("- ") or line.startswith("* "):
            story.append(Paragraph(f"• {line[2:]}", body_style))
        elif line:
            clean = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", line)
            story.append(Paragraph(clean, body_style))
        else:
            story.append(Spacer(1, 0.15*cm))
        i += 1

    # 푸터
    story.append(Spacer(1, 0.5*cm))
    story.append(HRFlowable(width="100%", thickness=0.5, color=colors.HexColor("#dde2ea"), spaceAfter=6))
    story.append(Paragraph(
        f"본 보고서는 AWS Bedrock AI가 자동 분석·생성하였습니다.  |  © {year} MZ Clinic",
        small_style))

    doc.build(story)
    return buf.getvalue()


# ── 이메일 발송 (HTML + PDF 첨부) ─────────────────────────────────────────

def _send_email(year: str, month: str, html_body: str, pdf_bytes: bytes):
    msg = MIMEMultipart("mixed")
    msg["Subject"] = f"[MZ클리닉 IT운영팀] {year}년 {int(month)}월 IT 인프라 운영비용 현황 보고"
    msg["From"]    = FROM_EMAIL
    msg["To"]      = ADMIN_EMAIL

    # HTML 본문
    alt = MIMEMultipart("alternative")
    alt.attach(MIMEText(html_body, "html", "utf-8"))
    msg.attach(alt)

    # PDF 첨부
    pdf_part = MIMEApplication(pdf_bytes, _subtype="pdf")
    pdf_part.add_header(
        "Content-Disposition", "attachment",
        filename=f"infra_report_{year}_{month}.pdf"
    )
    msg.attach(pdf_part)

    SES.send_raw_email(
        Source=FROM_EMAIL,
        Destinations=[ADMIN_EMAIL],
        RawMessage={"Data": msg.as_bytes()},
    )


# ── Lambda 핸들러 ──────────────────────────────────────────────────────────

def _api_response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,X-Api-Key",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def lambda_handler(event, context):
    # ── API Gateway 호출 감지 ──────────────────────────────
    is_api = bool(event.get("httpMethod") or event.get("requestContext"))

    if is_api:
        body = {}
        try:
            body = json.loads(event.get("body") or "{}")
        except Exception:
            pass

        send_email = body.get("send_email", False)
        year, month = _get_target_month()

        if not send_email:
            # 미리보기: 텍스트만 반환 (PDF 생략)
            cost_context = _load_raw_costs()
            report_text  = _generate_report(year, month, cost_context)
            return _api_response(200, {"report": report_text, "year": year, "month": month})

        else:
            # 이메일 발송: 비동기 Lambda 호출 후 즉시 반환
            boto3.client("lambda", region_name=os.environ.get("AWS_REGION", "ap-south-2")).invoke(
                FunctionName=context.function_name,
                InvocationType="Event",   # 비동기
                Payload=json.dumps({"force": True}).encode(),
            )
            return _api_response(200, {
                "message": f"{year}년 {int(month)}월 보고서 생성 후 이메일 발송합니다. 수 분 내 수신됩니다.",
                "status": "processing",
            })

    # ── EventBridge / 직접 호출 ────────────────────────────
    if not event.get("force") and not _is_third_monday():
        today = date.today()
        print(f"오늘({today})은 당월 3주차 월요일이 아닙니다. 발송 건너뜀.")
        return {"status": "skipped", "reason": "not_third_monday", "today": str(today)}

    year, month = _get_target_month()

    cost_context = _load_raw_costs()
    report_text  = _generate_report(year, month, cost_context)
    html_body    = _build_html(year, month, report_text)
    pdf_bytes    = _generate_pdf(year, month, report_text)

    # 보고서 텍스트 → 벡터 생성 후 S3 저장 (DIY RAG)
    try:
        _save_vectors(year, month, report_text)
    except Exception as e:
        print(f"Vector save failed (non-fatal): {e}")

    # PDF → S3 보관
    s3_key = f"cost/cost-reports/{year}/{month}/infra_report_{year}_{month}.pdf"
    S3.put_object(
        Bucket=STORAGE_BUCKET,
        Key=s3_key,
        Body=pdf_bytes,
        ContentType="application/pdf",
    )
    print(f"Report saved: s3://{STORAGE_BUCKET}/{s3_key} ({len(pdf_bytes)//1024}KB)")

    _send_email(year, month, html_body, pdf_bytes)
    print(f"Report sent: {year}-{month} → {ADMIN_EMAIL}")
    return {"status": "ok", "year": year, "month": month, "pdf_kb": len(pdf_bytes)//1024, "s3_key": s3_key}
