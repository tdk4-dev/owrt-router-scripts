#!/usr/bin/env python3
"""Render Router UI collateral only from validated manifest and release-rule inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any


HEX_40 = re.compile(r"^[0-9a-f]{40}$")
HEX_64 = re.compile(r"^[0-9a-f]{64}$")
SAFE_FILENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*$")


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def validate_inputs(
    manifest_path: Path,
    rules_path: Path,
    template_path: Path,
    mode: str,
    signature_proof_path: Path | None,
) -> dict[str, Any]:
    manifest = load_json(manifest_path)
    rules = load_json(rules_path)
    template = load_json(template_path)

    require(manifest.get("schema_version") == 1, "unsupported manifest schema")
    require(manifest.get("kind") == "installed-package-set", "unexpected manifest kind")
    require(rules.get("schema") == 1, "unsupported release-rules schema")
    require(template.get("schema") == 1, "unsupported collateral-template schema")
    require(manifest.get("source_dirty") is False, "dirty source provenance is refused")
    require(manifest.get("channel") in {"candidate", "stable"}, "invalid release channel")
    require(HEX_40.fullmatch(str(manifest.get("source_commit", ""))) is not None,
            "source commit must be a full lowercase SHA")
    require(HEX_40.fullmatch(str(manifest.get("source_tree", ""))) is not None,
            "source tree must be a full lowercase SHA")

    app_version = str(manifest.get("app_version", ""))
    package_version = str(manifest.get("package_version", ""))
    require(bool(app_version and package_version), "release identity is incomplete")
    expected_names = rules.get("project_packages")
    packages = manifest.get("packages")
    require(isinstance(expected_names, list) and len(expected_names) == 3,
            "release rules must define the three project packages")
    require(isinstance(packages, list) and len(packages) == len(expected_names),
            "manifest must contain exactly the shared project package set")

    total_bytes = 0
    for index, (expected_name, package) in enumerate(zip(expected_names, packages), start=1):
        require(isinstance(package, dict), f"package {index} must be an object")
        require(package.get("name") == expected_name, f"package {index} name/order mismatch")
        require(package.get("version") == package_version, f"{expected_name} version mismatch")
        require(package.get("architecture") == "all", f"{expected_name} architecture mismatch")
        require(package.get("install_order") == index, f"{expected_name} install order mismatch")
        require(SAFE_FILENAME.fullmatch(str(package.get("filename", ""))) is not None,
                f"{expected_name} has an unsafe filename")
        require(isinstance(package.get("size"), int) and package["size"] > 0,
                f"{expected_name} size is invalid")
        require(HEX_64.fullmatch(str(package.get("sha256", ""))) is not None,
                f"{expected_name} SHA-256 is invalid")
        total_bytes += package["size"]

    stable = rules.get("stable_successor", {})
    manifest_stable = manifest.get("stable_successor", {})
    require(manifest_stable.get("app_version") == stable.get("application_version"),
            "stable successor application version disagrees with shared rules")
    require(manifest_stable.get("package_version") == stable.get("package_version"),
            "stable successor package version disagrees with shared rules")

    storage = rules.get("storage", {})
    required_storage_keys = {
        "persistent_base_kib", "persistent_package_multiplier",
        "temporary_base_kib", "temporary_package_multiplier",
    }
    require(required_storage_keys.issubset(storage), "storage release rules are incomplete")
    package_kib = (total_bytes + 1023) // 1024
    persistent_kib = storage["persistent_base_kib"] + (
        package_kib * storage["persistent_package_multiplier"]
    )
    temporary_kib = storage["temporary_base_kib"] + (
        package_kib * storage["temporary_package_multiplier"]
    )

    manifest_digest = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    if mode == "fixture":
        require(manifest.get("production") is False, "fixture mode refuses production=true")
        require(manifest.get("collateral_status") == "fixture", "fixture status is required")
        banner = template["fixture_banner"]
    else:
        require(manifest.get("production") is True, "canonical mode requires production=true")
        require(manifest.get("collateral_status") == "canonical-signed",
                "canonical mode requires canonical-signed status")
        require(signature_proof_path is not None, "canonical mode requires signature proof")
        proof = load_json(signature_proof_path)
        require(proof.get("verified") is True, "signature proof is not verified")
        require(proof.get("manifest_sha256") == manifest_digest,
                "signature proof is for a different manifest")
        require(proof.get("signing_key_id") == manifest.get("signing_key_id"),
                "signature proof key does not match the manifest")
        banner = template["canonical_banner"]

    return {
        "manifest": manifest,
        "rules": rules,
        "template": template,
        "manifest_sha256": manifest_digest,
        "total_bytes": total_bytes,
        "package_kib": package_kib,
        "persistent_kib": persistent_kib,
        "temporary_kib": temporary_kib,
        "banner": banner,
        "mode": mode,
    }


def render_pdf(context: dict[str, Any], output: Path) -> None:
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_CENTER
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
    from reportlab.lib.units import mm
    from reportlab.platypus import (
        PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle
    )

    manifest = context["manifest"]
    template = context["template"]
    fixture = context["mode"] == "fixture"
    navy = colors.HexColor("#14283D")
    teal = colors.HexColor("#168C8C")
    orange = colors.HexColor("#E87722")
    red = colors.HexColor("#B53A35")
    pale = colors.HexColor("#F3F6F8")
    ink = colors.HexColor("#1E2A33")
    muted = colors.HexColor("#5E6D78")
    line = colors.HexColor("#D7E0E6")
    width = A4[0] - 34 * mm
    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle(name="GuideTitle", parent=styles["Title"], fontSize=25,
                              leading=29, textColor=navy, spaceAfter=5 * mm))
    styles.add(ParagraphStyle(name="GuideBody", parent=styles["BodyText"], fontSize=9.5,
                              leading=13.2, textColor=ink, spaceAfter=3 * mm))
    styles.add(ParagraphStyle(name="GuideSmall", parent=styles["BodyText"], fontSize=7.4,
                              leading=9.4, textColor=muted, spaceAfter=2 * mm))
    styles.add(ParagraphStyle(name="GuideBanner", parent=styles["Heading2"], fontSize=11,
                              leading=14, textColor=colors.white, alignment=TA_CENTER))
    styles.add(ParagraphStyle(name="GuideHash", parent=styles["Code"], fontSize=6,
                              leading=7.5, textColor=ink))

    def paragraph(text: str, style: str = "GuideBody") -> Paragraph:
        return Paragraph(text, styles[style])

    def banner(text: str, color: Any) -> Table:
        table = Table([[paragraph(text, "GuideBanner")]], colWidths=[width])
        table.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, -1), color),
            ("BOX", (0, 0), (-1, -1), 0.8, color),
            ("TOPPADDING", (0, 0), (-1, -1), 3 * mm),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3 * mm),
        ]))
        return table

    def facts_table(rows: list[list[Any]], widths: list[Any]) -> Table:
        table = Table(rows, colWidths=widths, repeatRows=1)
        table.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), navy),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("GRID", (0, 0), (-1, -1), 0.45, line),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, pale]),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 2.4 * mm),
            ("RIGHTPADDING", (0, 0), (-1, -1), 2.4 * mm),
            ("TOPPADDING", (0, 0), (-1, -1), 2.2 * mm),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 2.2 * mm),
        ]))
        return table

    title = template["title"].format(application_version=manifest["app_version"])
    story: list[Any] = [
        banner(context["banner"], red if fixture else teal),
        Spacer(1, 10 * mm),
        paragraph(title, "GuideTitle"),
        paragraph(template["subtitle"]),
        paragraph(template["summary"]),
        Spacer(1, 4 * mm),
        facts_table([
            ["Identity", "Validated manifest value"],
            ["Application / channel", f"{manifest['app_version']} / {manifest['channel']}"],
            ["Package version", manifest["package_version"]],
            ["Future tag convention", manifest["future_tag"]],
            ["Stable successor", f"{manifest['stable_successor']['app_version']} / {manifest['stable_successor']['package_version']}"],
            ["Source commit / tree", paragraph(f"{manifest['source_commit']}<br/>{manifest['source_tree']}", "GuideHash")],
            ["Manifest SHA-256", paragraph(context["manifest_sha256"], "GuideHash")],
        ], [48 * mm, width - 48 * mm]),
        Spacer(1, 8 * mm),
        banner("FIXTURE VALUES BELOW ARE SYNTHETIC" if fixture else "MANIFEST FACTS", orange if fixture else teal),
        Spacer(1, 4 * mm),
        paragraph("This document was generated from the supplied manifest. The generator contains no package hashes, sizes, source identity, or storage thresholds."),
        PageBreak(),
        paragraph("Manifest package facts", "GuideTitle"),
    ]

    package_rows: list[list[Any]] = [["Order / package", "Bytes", "SHA-256"]]
    for package in manifest["packages"]:
        package_rows.append([
            paragraph(f"{package['install_order']}. {package['filename']}", "GuideSmall"),
            f"{package['size']:,}",
            paragraph(package["sha256"], "GuideHash"),
        ])
    story.extend([
        facts_table(package_rows, [66 * mm, 22 * mm, width - 88 * mm]),
        Spacer(1, 6 * mm),
        paragraph("Derived storage gates", "GuideTitle"),
        facts_table([
            ["Derived fact", "Value"],
            ["Package total", f"{context['total_bytes']:,} bytes ({context['package_kib']} KiB rounded up)"],
            ["Persistent minimum", f"{context['persistent_kib']:,} KiB"],
            ["Temporary /tmp minimum", f"{context['temporary_kib']:,} KiB"],
        ], [60 * mm, width - 60 * mm]),
        Spacer(1, 5 * mm),
        paragraph(template["healthy_adopted"]),
        paragraph(template["fail_closed"]),
        PageBreak(),
        paragraph("Checkpoint sequence", "GuideTitle"),
    ])
    for index, step in enumerate(template["steps"], start=1):
        story.append(paragraph(f"<b>{index}.</b> {step}"))
    story.extend([Spacer(1, 4 * mm), paragraph("Hard stops", "GuideTitle")])
    for stop in template["stops"]:
        story.append(paragraph(f"• {stop}"))
    story.extend([
        Spacer(1, 7 * mm),
        banner("THIS FIXTURE IS VISUAL QA ONLY — DO NOT DISTRIBUTE OR INSTALL" if fixture
               else "USE ONLY WITH THE EXACT SIGNED MANIFEST", red if fixture else teal),
        Spacer(1, 4 * mm),
        paragraph("A source, packaged-document, build/staging input, or contract-input change invalidates a frozen RC candidate and requires a new candidate identity.", "GuideSmall"),
    ])

    output.parent.mkdir(parents=True, exist_ok=True)
    doc = SimpleDocTemplate(
        str(output), pagesize=A4, leftMargin=17 * mm, rightMargin=17 * mm,
        topMargin=18 * mm, bottomMargin=17 * mm,
        title=f"{title} {'non-production fixture' if fixture else 'installation guide'}",
        author="Premier Router",
        subject="Manifest-driven Router UI release collateral",
    )

    def footer(canvas: Any, document: Any) -> None:
        canvas.saveState()
        canvas.setStrokeColor(line)
        canvas.line(17 * mm, 11.5 * mm, A4[0] - 17 * mm, 11.5 * mm)
        canvas.setFillColor(red if fixture else muted)
        canvas.setFont("Helvetica-Bold" if fixture else "Helvetica", 7)
        canvas.drawString(17 * mm, 7.5 * mm, "NON-PRODUCTION FIXTURE" if fixture else manifest["app_version"])
        canvas.setFillColor(muted)
        canvas.drawRightString(A4[0] - 17 * mm, 7.5 * mm, f"Page {document.page}")
        canvas.restoreState()

    doc.build(story, onFirstPage=footer, onLaterPages=footer)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--rules", type=Path, required=True)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--mode", choices=("fixture", "canonical"), required=True)
    parser.add_argument("--signature-proof", type=Path)
    parser.add_argument("--validate-only", action="store_true")
    return parser.parse_args()


def enforce_tier0_guard(args: argparse.Namespace) -> None:
    guard_path = os.environ.get("ROUTER_UI_TIER0_GUARD_LOG")
    if not guard_path:
        return
    if args.validate_only and args.output is None:
        return
    with open(guard_path, "a", encoding="utf-8") as guard_log:
        guard_log.write("staging:render-router-ui-install-guide.py\n")
    raise SystemExit(97)


def main() -> None:
    args = parse_args()
    enforce_tier0_guard(args)
    require(not (args.validate_only and args.output is not None),
            "--validate-only cannot be combined with --output")
    context = validate_inputs(
        args.manifest, args.rules, args.template, args.mode, args.signature_proof
    )
    if args.validate_only:
        print(json.dumps({
            "ok": True,
            "mode": context["mode"],
            "manifest_sha256": context["manifest_sha256"],
            "total_bytes": context["total_bytes"],
            "persistent_kib": context["persistent_kib"],
            "temporary_kib": context["temporary_kib"],
        }, sort_keys=True))
        return
    require(args.output is not None, "--output is required unless --validate-only is used")
    render_pdf(context, args.output)
    print(args.output)


if __name__ == "__main__":
    main()
