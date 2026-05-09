"""Typer CLI for the outreach toolkit.

Usage:
  python -m outreach init
  python -m outreach import data/leads.csv
  python -m outreach analyze --limit 5
  python -m outreach plan <lead_id>
  python -m outreach approve --all | --id 12 | --batch 10
  python -m outreach send                     # dry-run by default
  python -m outreach send --live              # actually submit forms
  python -m outreach status
  python -m outreach report
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

import typer
from rich.console import Console
from rich.table import Table

from . import analyzer, config, db, form_filler, importer, reporter

app = typer.Typer(add_completion=False, help="Automated lead outreach")
console = Console()


@app.command()
def init() -> None:
    """Create the SQLite DB schema."""
    path = db.init_db()
    console.print(f"[green]DB ready[/green] at {path}")


@app.command("import")
def import_cmd(file: Path) -> None:
    """Import leads from CSV/XLSX into the DB."""
    if not file.exists():
        raise typer.BadParameter(f"File not found: {file}")
    stats = importer.import_file(file)
    console.print(
        f"[green]Imported[/green] {stats['inserted']} leads "
        f"(skipped {stats['skipped']}). Channels: {stats['by_channel']}"
    )


@app.command()
def analyze(
    limit: int = typer.Option(0, help="Max leads to analyze (0 = all 'new')"),
    only_id: Optional[int] = typer.Option(None, "--id", help="Analyze a single lead"),
) -> None:
    """Fetch + analyze each new lead's site, generate offer, save plan."""
    config.load_env()
    sender = config.load_sender()
    base_offer = config.load_offer()

    with db.session() as conn:
        if only_id:
            row = db.get_lead(conn, only_id)
            leads = [row] if row else []
        else:
            leads = db.fetch_leads(conn, status="new", limit=limit or None)

        if not leads:
            console.print("[yellow]No leads to analyze[/yellow]")
            return

        for lead in leads:
            lead_dict = dict(lead)
            console.rule(f"[bold]#{lead['id']} {lead['company']}")
            try:
                analysis = analyzer.analyze_site(lead_dict)
            except Exception as exc:  # noqa: BLE001
                console.print(f"[red]analyze failed:[/red] {exc}")
                db.update_lead(conn, lead["id"], status="failed", last_error=str(exc)[:500])
                conn.commit()
                continue

            if analysis.get("error"):
                console.print(f"[yellow]skipped:[/yellow] {analysis['error']}")
                db.update_lead(conn, lead["id"], status="skipped",
                               last_error=analysis["error"])
                conn.commit()
                continue

            try:
                offer = analyzer.personalize_offer(
                    lead_dict, analysis, sender, base_offer,
                    channel=lead["channel"] or "form",
                )
            except Exception as exc:  # noqa: BLE001
                console.print(f"[red]offer gen failed:[/red] {exc}")
                db.update_lead(conn, lead["id"], status="failed", last_error=str(exc)[:500])
                conn.commit()
                continue

            if offer.get("skip"):
                console.print(f"[yellow]LLM skipped:[/yellow] {offer.get('skip_reason')}")
                db.update_lead(
                    conn, lead["id"],
                    status="skipped",
                    last_error=offer.get("skip_reason"),
                    site_summary=analysis.get("summary"),
                    language=analysis.get("language"),
                )
                conn.commit()
                continue

            plan = {"analysis": analysis, "offer": offer}
            db.update_lead(
                conn, lead["id"],
                status="analyzed",
                site_summary=analysis.get("summary"),
                language=analysis.get("language"),
                offer_text=offer.get("body"),
                form_plan=json.dumps(plan, ensure_ascii=False),
                last_error=None,
            )
            conn.commit()
            console.print(
                f"[green]ready[/green] | {analysis.get('industry')} | "
                f"subj=“{offer.get('subject')}”"
            )


@app.command()
def plan(lead_id: int) -> None:
    """Show the generated offer + analysis for a lead."""
    with db.session() as conn:
        lead = db.get_lead(conn, lead_id)
    if not lead:
        raise typer.Exit("Lead not found")
    console.rule(f"#{lead['id']} {lead['company']}  [{lead['status']}]")
    console.print(f"[bold]Website:[/bold] {lead['website']}")
    console.print(f"[bold]Form URL:[/bold] {lead['form_url']}")
    console.print(f"[bold]Channel:[/bold] {lead['channel']}")
    console.print(f"[bold]Language:[/bold] {lead['language']}")
    console.print(f"[bold]Summary:[/bold] {lead['site_summary']}")
    if lead["form_plan"]:
        try:
            plan = json.loads(lead["form_plan"])
        except json.JSONDecodeError:
            plan = {}
        offer = plan.get("offer", {})
        console.rule("Offer")
        console.print(f"[bold]Subject:[/bold] {offer.get('subject')}")
        console.print(f"[bold]First line:[/bold] {offer.get('first_line')}")
        console.print(f"[bold]CTA:[/bold] {offer.get('cta')}")
        console.print()
        console.print(offer.get("body") or "")


@app.command()
def approve(
    all_: bool = typer.Option(False, "--all", help="Approve every analyzed lead"),
    only_id: Optional[int] = typer.Option(None, "--id"),
    batch: int = typer.Option(0, "--batch", help="Approve first N analyzed leads"),
) -> None:
    """Mark analyzed leads as approved → ready to send."""
    if not (all_ or only_id or batch):
        raise typer.BadParameter("Specify --all, --id or --batch")

    with db.session() as conn:
        if only_id:
            db.update_lead(conn, only_id, status="approved")
            count = 1
        else:
            leads = db.fetch_leads(conn, status="analyzed", limit=batch or None) if not all_ else \
                    db.fetch_leads(conn, status="analyzed")
            count = 0
            for lead in leads:
                db.update_lead(conn, lead["id"], status="approved")
                count += 1
    console.print(f"[green]Approved[/green] {count} lead(s)")


@app.command()
def send(
    live: bool = typer.Option(False, "--live", help="Actually submit (default: dry-run)"),
    limit: int = typer.Option(0, help="Limit number of leads (0 = all approved)"),
    only_id: Optional[int] = typer.Option(None, "--id"),
) -> None:
    """Submit contact forms for approved leads."""
    config.load_env()
    sender = config.load_sender()

    with db.session() as conn:
        if only_id:
            row = db.get_lead(conn, only_id)
            if not row:
                raise typer.Exit("Lead not found")
            leads = [row]
        else:
            leads = db.fetch_leads(conn, status="approved", limit=limit or None)

        if not leads:
            console.print("[yellow]No approved leads.[/yellow] Run `analyze` and `approve` first.")
            return

        for lead in leads:
            console.rule(f"#{lead['id']} {lead['company']}  [{lead['channel']}]")
            target = lead["form_url"] or lead["website"]
            if not target:
                console.print("[yellow]no URL — skipping[/yellow]")
                db.update_lead(conn, lead["id"], status="skipped", last_error="no URL")
                conn.commit()
                continue

            if (lead["channel"] or "form") != "form":
                console.print(f"[yellow]channel {lead['channel']} not yet implemented — skipping[/yellow]")
                continue

            try:
                plan = json.loads(lead["form_plan"] or "{}")
            except json.JSONDecodeError:
                plan = {}
            offer = plan.get("offer") or {}
            message = offer.get("body") or ""
            subject = offer.get("subject")
            if not message:
                console.print("[red]no message — run `analyze` first[/red]")
                continue

            db.update_lead(conn, lead["id"], status="sending", last_error=None)
            conn.commit()

            try:
                outcome = form_filler.fill_and_submit(
                    lead_id=lead["id"],
                    url=target,
                    sender=sender,
                    message=message,
                    subject=subject,
                    dry_run=not live,
                )
            except Exception as exc:  # noqa: BLE001
                console.print(f"[red]fill error:[/red] {exc}")
                db.update_lead(conn, lead["id"], status="failed", last_error=str(exc)[:500])
                conn.commit()
                continue

            if not live:
                console.print(
                    f"[cyan]dry-run plan ready[/cyan] "
                    f"(fields: {len(outcome.strategy.get('fields') or [])}, "
                    f"submit: {outcome.strategy.get('submit_selector')!r})"
                )
                db.record_attempt(
                    conn, lead["id"], "form",
                    strategy=outcome.strategy,
                    success=False,
                    error="dry-run",
                )
                # status stays "approved" so user can re-run with --live
                conn.commit()
                continue

            db.record_attempt(
                conn, lead["id"], "form",
                strategy=outcome.strategy,
                success=outcome.success,
                confirmation=outcome.confirmation,
                error=outcome.error,
                screenshot=outcome.screenshots[-1] if outcome.screenshots else None,
            )
            if outcome.success:
                console.print(f"[green]sent[/green] — {outcome.confirmation or 'OK'}")
                db.update_lead(conn, lead["id"], status="sent", last_error=None)
            elif outcome.aborted:
                console.print(f"[yellow]aborted:[/yellow] {outcome.abort_reason}")
                db.update_lead(conn, lead["id"], status="skipped",
                               last_error=outcome.abort_reason)
            else:
                console.print(f"[red]failed:[/red] {outcome.error}")
                db.update_lead(conn, lead["id"], status="failed", last_error=outcome.error)
            conn.commit()


@app.command()
def status() -> None:
    """Print a summary of leads by status."""
    with db.session() as conn:
        counts = db.status_counts(conn)
        total = conn.execute("SELECT COUNT(*) AS n FROM leads").fetchone()["n"]

    table = Table(title=f"Leads ({total} total)")
    table.add_column("Status")
    table.add_column("Count", justify="right")
    for status_name in ("new", "analyzed", "approved", "sending", "sent",
                        "failed", "skipped", "replied"):
        table.add_row(status_name, str(counts.get(status_name, 0)))
    console.print(table)


@app.command()
def report() -> None:
    """Export a CSV report of every lead and its outcome."""
    out = reporter.export()
    console.print(f"[green]Wrote[/green] {out}")


if __name__ == "__main__":
    app()
