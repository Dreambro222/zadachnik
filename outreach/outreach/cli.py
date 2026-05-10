"""Typer CLI for the outreach toolkit.

Pipeline:

    init                       create the SQLite DB
    import <file.csv>          ingest leads
    research [--limit N]       Playwright + Claude (with WebSearch) → deep
                               per-company research saved on each lead
    plan [--limit N]           generate full multi-turn conversation playbook
                               from each lead's research
    analyze [--limit N]        shorthand: research + plan in one go
    playbook <id>              export ONE lead's playbook to markdown
    playbooks                  export EVERY lead's playbook into one big file
    approve                    move a lead from analyzed → approved (gate)
    mail [--id --step --live]  EMAIL channel: send the chosen step via SMTP
    send [--id --live]         FORM channel: submit the contact form
    inbox [--once]             poll IMAP, attach replies, classify
    reply <id>                 paste an inbound reply (manual fallback)
    status / report            dashboard + CSV
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Optional

import typer
from rich.console import Console
from rich.markdown import Markdown
from rich.table import Table

from . import (
    config, conversation, db, form_filler, importer, inbox as inbox_mod,
    mailer, playbook, reporter, research,
)

app = typer.Typer(add_completion=False, help="Automated lead outreach")
console = Console()


# ---------- core lifecycle ----------

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


@app.command("research")
def research_cmd(
    limit: int = typer.Option(0, help="Max leads to research (0 = all 'new')"),
    only_id: Optional[int] = typer.Option(None, "--id"),
    refresh: bool = typer.Option(False, help="Re-research even if already done"),
) -> None:
    """Run deep per-lead research (Playwright + Claude + WebSearch)."""
    config.load_env()

    with db.session() as conn:
        if only_id:
            row = db.get_lead(conn, only_id)
            leads = [row] if row else []
        else:
            statuses = ["new"] if not refresh else ["new", "skipped", "failed", "analyzed"]
            leads = db.fetch_leads(conn, status=statuses, limit=limit or None)

        if not leads:
            console.print("[yellow]No leads to research[/yellow]")
            return

        for lead in leads:
            lead_dict = dict(lead)
            console.rule(f"[bold]#{lead['id']} {lead['company']}")

            if lead["channel"] == "tender_only":
                console.print(
                    f"[yellow]tender-only ({lead['category']}) — skipping[/yellow]"
                )
                db.update_lead(conn, lead["id"], status="skipped",
                               last_error="tender-only category")
                conn.commit()
                continue

            if lead["research"] and not refresh:
                console.print("[cyan]already researched — use --refresh to redo[/cyan]")
                continue

            try:
                result = research.deep_research(lead_dict)
            except Exception as exc:  # noqa: BLE001
                console.print(f"[red]research failed:[/red] {exc}")
                db.update_lead(conn, lead["id"], status="failed",
                               last_error=str(exc)[:500])
                conn.commit()
                continue

            if result.get("skip"):
                console.print(f"[yellow]skip:[/yellow] {result.get('skip_reason')}")
                db.update_lead(
                    conn, lead["id"],
                    status="skipped",
                    last_error=result.get("skip_reason"),
                    research=json.dumps(result, ensure_ascii=False),
                )
            else:
                console.print(
                    f"[green]ok[/green] | {result.get('chinese_exposure', '?')} chinese · "
                    f"{len(result.get('pain_points') or [])} pains · "
                    f"{len(result.get('recommended_models') or [])} models suggested"
                )
                db.update_lead(
                    conn, lead["id"],
                    status="researched",
                    research=json.dumps(result, ensure_ascii=False),
                    site_summary=result.get("business_model"),
                    language=result.get("site_language"),
                    last_error=None,
                )
            conn.commit()


@app.command()
def plan(
    limit: int = typer.Option(0, help="Max leads to plan (0 = all researched)"),
    only_id: Optional[int] = typer.Option(None, "--id"),
    refresh: bool = typer.Option(False, help="Re-plan even if already done"),
) -> None:
    """Generate full multi-turn conversation playbook from each lead's research."""
    config.load_env()
    sender = config.load_sender()
    base_offer = config.load_offer()

    with db.session() as conn:
        if only_id:
            row = db.get_lead(conn, only_id)
            leads = [row] if row else []
        else:
            leads = db.fetch_leads(conn, status="researched", limit=limit or None)

        if not leads:
            console.print(
                "[yellow]No researched leads. Run `outreach research` first.[/yellow]"
            )
            return

        for lead in leads:
            console.rule(f"[bold]#{lead['id']} {lead['company']}")

            if not lead["research"]:
                console.print("[red]no research on this lead — skipping[/red]")
                continue
            if lead["conversation"] and not refresh:
                console.print("[cyan]already planned — use --refresh to redo[/cyan]")
                continue

            research_blob = json.loads(lead["research"])
            try:
                result = conversation.plan_conversation(
                    dict(lead), research_blob, sender, base_offer,
                    channel=lead["channel"] or "form",
                )
            except Exception as exc:  # noqa: BLE001
                console.print(f"[red]plan failed:[/red] {exc}")
                db.update_lead(conn, lead["id"], status="failed",
                               last_error=str(exc)[:500])
                conn.commit()
                continue

            if result.get("skip"):
                console.print(f"[yellow]skip:[/yellow] {result.get('skip_reason')}")
                db.update_lead(
                    conn, lead["id"],
                    status="skipped",
                    last_error=result.get("skip_reason"),
                    conversation=json.dumps(result, ensure_ascii=False),
                )
            else:
                ft = result.get("first_touch") or {}
                obj_count = len(result.get("objection_handlers") or [])
                fu_count = len(result.get("followups") or [])
                console.print(
                    f"[green]ok[/green] | subj=\"{ft.get('subject', '')}\" "
                    f"· {obj_count} objections · {fu_count} follow-ups"
                )
                db.update_lead(
                    conn, lead["id"],
                    status="analyzed",   # ready for approve / send
                    conversation=json.dumps(result, ensure_ascii=False),
                    offer_text=ft.get("body"),
                    current_step="first_touch",
                    last_error=None,
                )
            conn.commit()


@app.command()
def analyze(
    limit: int = typer.Option(0, help="Max leads to process"),
    only_id: Optional[int] = typer.Option(None, "--id"),
) -> None:
    """Convenience: research + plan, in one pass."""
    research_cmd(limit=limit, only_id=only_id, refresh=False)
    plan(limit=limit, only_id=only_id, refresh=False)


# ---------- review surface ----------

@app.command("playbook")
def playbook_cmd(
    lead_id: int,
    show: bool = typer.Option(True, help="Print rendered markdown to stdout"),
) -> None:
    """Export ONE lead's full playbook to playbooks/leadXX-<slug>.md."""
    out = playbook.export_lead(lead_id)
    console.print(f"[green]Wrote[/green] {out}")
    if show:
        console.print(Markdown(out.read_text(encoding="utf-8")))


@app.command("playbooks")
def playbooks_cmd() -> None:
    """Export every lead's playbook into one combined markdown file."""
    out = playbook.export_all()
    console.print(f"[green]Wrote[/green] {out}")


# ---------- inbound replies ----------

@app.command("reply")
def reply_cmd(
    lead_id: int,
    subject: str = typer.Option("", help="Reply subject"),
    sender_email: str = typer.Option("", "--from", help="Reply sender address"),
    body_file: Optional[Path] = typer.Option(
        None, "--body-file",
        help="Path to a file with the reply body. If omitted, read stdin.",
    ),
) -> None:
    """Classify an inbound reply against the prepared playbook + suggest the
    next move. The reply is logged to the messages table.
    """
    if body_file and body_file.exists():
        body = body_file.read_text(encoding="utf-8")
    else:
        console.print("[dim]Paste the reply body, then Ctrl-D to finish:[/dim]")
        body = sys.stdin.read()

    if not body.strip():
        raise typer.BadParameter("Empty reply body")

    with db.session() as conn:
        lead = db.get_lead(conn, lead_id)
        if not lead:
            raise typer.Exit("Lead not found")
        plan_blob = json.loads(lead["conversation"] or "{}")
        if not plan_blob:
            raise typer.Exit("This lead has no conversation plan yet — run `plan` first")

        history = [dict(m) for m in db.message_history(conn, lead_id)]

        db.record_message(
            conn, lead_id,
            direction="inbound",
            channel="email",
            subject=subject or None,
            body=body,
            raw=json.dumps({"from": sender_email}, ensure_ascii=False),
        )
        conn.commit()

        verdict = conversation.classify_reply(
            dict(lead), plan_blob, history,
            {"subject": subject, "body": body, "from": sender_email},
        )

        # Update the inbound message with the classification.
        conn.execute(
            """UPDATE messages SET classification = ?, confidence = ?
               WHERE lead_id = ? AND id = (SELECT MAX(id) FROM messages WHERE lead_id = ?)""",
            (verdict.get("classification"), verdict.get("confidence"),
             lead_id, lead_id),
        )
        conn.commit()

    console.rule(f"[bold]#{lead_id} {lead['company']}: reply classification")
    console.print(f"**Class:** {verdict.get('classification')} · "
                  f"sentiment {verdict.get('sentiment')} · "
                  f"urgency {verdict.get('urgency')} · "
                  f"conf {verdict.get('confidence')}")
    if verdict.get("matched_objection_key"):
        console.print(f"**Matched objection:** {verdict['matched_objection_key']}")
    console.print(f"**Recommended action:** {verdict.get('recommended_action')}")
    console.print(f"**Rationale:** {verdict.get('rationale')}")
    if verdict.get("must_human_review"):
        console.print("[red]🚨 must_human_review = true[/red]")
    if verdict.get("suggested_subject") or verdict.get("suggested_body"):
        console.rule("Suggested response")
        if verdict.get("suggested_subject"):
            console.print(f"**Subject:** {verdict['suggested_subject']}")
        console.print(verdict.get("suggested_body") or "")


# ---------- approval + send ----------

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
            leads = (db.fetch_leads(conn, status="analyzed")
                     if all_ else
                     db.fetch_leads(conn, status="analyzed", limit=batch or None))
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
    """Submit contact forms for approved leads using their first_touch message."""
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
            console.print("[yellow]No approved leads.[/yellow]")
            return

        for lead in leads:
            console.rule(f"#{lead['id']} {lead['company']}  [{lead['channel']}]")
            target = lead["form_url"] or lead["website"]
            if not target:
                console.print("[yellow]no URL — skipping[/yellow]")
                db.update_lead(conn, lead["id"], status="skipped",
                               last_error="no URL")
                conn.commit()
                continue

            if lead["channel"] == "tender_only":
                console.print(f"[yellow]tender-only — skipping[/yellow]")
                continue
            if (lead["channel"] or "form") != "form":
                console.print(
                    f"[yellow]channel {lead['channel']} not yet implemented — skipping[/yellow]"
                )
                continue

            plan_blob = json.loads(lead["conversation"] or "{}")
            ft = (plan_blob.get("first_touch") or {})
            body = (ft.get("body") or "").strip()
            footer = (ft.get("compliance_footer") or "").strip()
            subject = ft.get("subject")
            if not body:
                console.print("[red]no first_touch body — run `plan` first[/red]")
                continue
            if not footer:
                console.print(
                    "[red]missing compliance footer (POPIA s.69) — refusing[/red]"
                )
                db.update_lead(conn, lead["id"], status="failed",
                               last_error="missing compliance_footer")
                conn.commit()
                continue
            message = f"{body}\n\n{footer}"

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
                db.update_lead(conn, lead["id"], status="failed",
                               last_error=str(exc)[:500])
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
                db.record_message(
                    conn, lead["id"],
                    direction="outbound", channel="form", step="first_touch",
                    subject=subject, body=message,
                )
                console.print(f"[green]sent[/green] — {outcome.confirmation or 'OK'}")
                db.update_lead(conn, lead["id"], status="sent", last_error=None,
                               current_step="first_touch_sent")
            elif outcome.aborted:
                console.print(f"[yellow]aborted:[/yellow] {outcome.abort_reason}")
                db.update_lead(conn, lead["id"], status="skipped",
                               last_error=outcome.abort_reason)
            else:
                console.print(f"[red]failed:[/red] {outcome.error}")
                db.update_lead(conn, lead["id"], status="failed",
                               last_error=outcome.error)
            conn.commit()


# ---------- email channel ----------

def _step_message(plan: dict, step: str) -> tuple[str, str, str] | None:
    """Return (subject, body, footer) for the requested step from the plan,
    or None if the step is not available. ``footer`` comes from first_touch
    (POPIA s.69 footer is reused for every subsequent step)."""
    if not plan:
        return None
    ft = plan.get("first_touch") or {}
    footer = (ft.get("compliance_footer") or "").strip()
    if step == "first_touch":
        return ft.get("subject", ""), (ft.get("body") or "").strip(), footer
    for f in plan.get("followups") or []:
        if f.get("step_key") == step:
            return f.get("subject", ""), (f.get("body") or "").strip(), footer
    if step == "close":
        cm = plan.get("close_message") or {}
        return cm.get("subject", ""), (cm.get("body") or "").strip(), footer
    if step.startswith("objection_"):
        key = step[len("objection_"):]
        for o in plan.get("objection_handlers") or []:
            if o.get("objection_key") == key:
                return (
                    o.get("reply_subject", ""),
                    (o.get("reply_body") or "").strip(),
                    footer,
                )
    return None


@app.command()
def mail(
    only_id: Optional[int] = typer.Option(None, "--id"),
    limit: int = typer.Option(0, help="Max leads to send to (0 = all approved with email)"),
    step: str = typer.Option(
        "first_touch",
        help="Which step from the playbook to send: "
             "first_touch | followup_1 | followup_2 | nurture_30d | "
             "close | objection_<key>",
    ),
    live: bool = typer.Option(False, "--live", help="Actually send (default: dry-run)"),
) -> None:
    """Send the chosen playbook step via EMAIL (SMTP) to approved leads."""
    cfg = config.load_mailer()

    with db.session() as conn:
        if only_id:
            row = db.get_lead(conn, only_id)
            if not row:
                raise typer.Exit("Lead not found")
            leads = [row]
        else:
            # All approved leads that have a usable email address.
            sql = """SELECT * FROM leads
                     WHERE email IS NOT NULL AND email != ''
                       AND status IN ('approved', 'sent', 'replied')
                     ORDER BY id"""
            leads = list(conn.execute(sql))
            if limit:
                leads = leads[:limit]

        if not leads:
            console.print(
                "[yellow]No leads with an email address in approved/sent status.[/yellow]"
            )
            return

        # Daily-limit gate (only counted in --live mode).
        if live:
            today_count = db.count_messages_today(conn, channel="email")
            remaining = cfg.daily_limit - today_count
            if remaining <= 0:
                console.print(
                    f"[red]Daily mail limit hit ({cfg.daily_limit}). "
                    f"Try again tomorrow or raise MAIL_DAILY_LIMIT.[/red]"
                )
                return
            leads = leads[:remaining]

        sent = 0
        for lead in leads:
            console.rule(f"#{lead['id']} {lead['company']}  [{step}]")
            if not (lead["email"] or "").strip():
                console.print("[yellow]no email — skipping[/yellow]")
                continue

            plan_blob = json.loads(lead["conversation"] or "{}")
            chosen = _step_message(plan_blob, step)
            if not chosen:
                console.print(
                    f"[red]step `{step}` not in plan — run `plan` first[/red]"
                )
                continue
            subject_raw, body, footer = chosen
            if not body:
                console.print(f"[red]empty body for step `{step}`[/red]")
                continue
            try:
                full_body = mailer.assemble_body(body, footer)
            except mailer.MailError as exc:
                console.print(f"[red]{exc}[/red]")
                db.update_lead(
                    conn, lead["id"], status="failed",
                    last_error=f"mail/{step}: {exc}",
                )
                conn.commit()
                continue

            # For non-first-touch steps we thread under the original outbound.
            in_reply_to = None
            references: list[str] = []
            thread_id = None
            if step != "first_touch":
                first = conn.execute(
                    """SELECT message_id, thread_id FROM messages
                       WHERE lead_id = ? AND direction = 'outbound'
                         AND step = 'first_touch' AND message_id IS NOT NULL
                       ORDER BY id LIMIT 1""",
                    (lead["id"],),
                ).fetchone()
                if first and first["message_id"]:
                    in_reply_to = first["message_id"]
                    references = [first["message_id"]]
                    thread_id = first["thread_id"] or first["message_id"]

            subject = mailer.thread_subject(
                subject_raw, is_followup=(step != "first_touch")
            )

            outbound = mailer.OutboundMessage(
                to_email=lead["email"],
                to_name=lead["contact_name"] or lead["company"],
                subject=subject,
                body_plain=full_body,
                in_reply_to=in_reply_to,
                references=references,
                reply_to=cfg.reply_to,
            )

            try:
                result = mailer.send(outbound, cfg, dry_run=not live)
            except Exception as exc:  # noqa: BLE001
                console.print(f"[red]send failed:[/red] {exc}")
                db.update_lead(conn, lead["id"], status="failed",
                               last_error=str(exc)[:500])
                conn.commit()
                continue

            if not live:
                console.print(
                    f"[cyan]dry-run[/cyan]  to={lead['email']}  "
                    f"msg-id={result.message_id}\n"
                    f"  subj=\"{subject}\""
                )
                continue

            db.record_message(
                conn, lead["id"],
                direction="outbound", channel="email", step=step,
                subject=subject, body=full_body,
                message_id=result.message_id,
                in_reply_to=in_reply_to,
                thread_id=thread_id or result.message_id,
                from_addr=cfg.from_email,
                to_addr=lead["email"],
                raw=result.raw_envelope,
            )
            new_status = "sent" if step == "first_touch" else lead["status"]
            db.update_lead(
                conn, lead["id"],
                status=new_status,
                current_step=f"{step}_sent",
                last_error=None,
            )
            conn.commit()
            sent += 1
            console.print(
                f"[green]sent[/green]  to={lead['email']}  "
                f"msg-id={result.message_id}"
            )
            if cfg.delay_seconds and lead is not leads[-1]:
                time.sleep(cfg.delay_seconds)

        console.print(f"\n[bold]Sent {sent} email(s)[/bold]" if live else
                      "\n[dim]dry-run finished[/dim]")


@app.command()
def inbox(
    once: bool = typer.Option(True, "--once/--watch", help="One poll vs loop"),
    no_classify: bool = typer.Option(False, help="Skip the LLM classifier"),
) -> None:
    """Poll the IMAP inbox, attach replies to leads, run classify_reply on each."""
    cfg = config.load_inbox()

    def _one_pass() -> None:
        try:
            summary = inbox_mod.ingest(inbox_cfg=cfg, classify=not no_classify)
        except Exception as exc:  # noqa: BLE001
            console.print(f"[red]inbox poll failed:[/red] {exc}")
            return
        console.print(
            f"fetched={summary['fetched']}  attached={summary['attached']}  "
            f"classified={summary['classified']}  "
            f"unattached={len(summary['unattached'])}"
        )
        for u in summary["unattached"]:
            console.print(f"  [dim]?  {u['from']}  \"{u['subject']}\"[/dim]")

    if once:
        _one_pass()
        return

    console.print(f"[dim]watching {cfg.host}/{cfg.folder} every {cfg.poll_seconds}s "
                  f"(Ctrl-C to stop)[/dim]")
    while True:
        _one_pass()
        time.sleep(cfg.poll_seconds)


# ---------- dashboards ----------

@app.command()
def status() -> None:
    """Print a summary of leads by status."""
    with db.session() as conn:
        counts = db.status_counts(conn)
        total = conn.execute("SELECT COUNT(*) AS n FROM leads").fetchone()["n"]

    table = Table(title=f"Leads ({total} total)")
    table.add_column("Status")
    table.add_column("Count", justify="right")
    for status_name in ("new", "researched", "analyzed", "approved", "sending",
                        "sent", "failed", "skipped", "replied"):
        table.add_row(status_name, str(counts.get(status_name, 0)))
    console.print(table)


@app.command()
def report() -> None:
    """Export a CSV report of every lead and its outcome."""
    out = reporter.export()
    console.print(f"[green]Wrote[/green] {out}")


if __name__ == "__main__":
    app()
