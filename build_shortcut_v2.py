#!/usr/bin/env python3
"""
Generate MailOverClone v2.shortcut
Improvements over v1:
  - Date retrieved upfront (used in prompt + note title)
  - Body truncated to ~200 chars via chained aggrandizements
  - 4-category prompt (added 🗑 SKIP for newsletters/promotions)
  - Date + email count injected into GPT prompt for context
  - "⏳ Procesando…" start notification with count
  - Richer note title: "📬 Briefing 01/06/2026 — 8 correos"
  - Final notification includes count
  - If/Otherwise/End-If wraps the whole flow (cleaner than exit-inside-if)
  - Conditional: count != 0 to enter main block
"""
import plistlib, uuid, hashlib

PLACEHOLDER = "￼"   # U+FFFC


def uu():
    return str(uuid.uuid4()).upper()


def ts(parts):
    """Build WFTextTokenString from list of str | dict(output_uuid, output_name?, agg?)."""
    s, att = "", {}
    for p in parts:
        if isinstance(p, str):
            s += p
        else:
            pos = len(s)
            s += PLACEHOLDER
            e = {"OutputUUID": p["output_uuid"], "OutputName": p.get("output_name", ""), "Type": "ActionOutput"}
            if "agg" in p:
                e["Aggrandizements"] = p["agg"]
            att["{%d, 1}" % pos] = e
    return {"WFSerializationType": "WFTextTokenString", "Value": {"string": s, "attachmentsByRange": att}}


def ref(uuid_, name="", agg=None):
    """WFTextTokenAttachment reference."""
    v = {"OutputUUID": uuid_, "OutputName": name, "Type": "ActionOutput"}
    if agg:
        v["Aggrandizements"] = agg
    return {"WFSerializationType": "WFTextTokenAttachment", "Value": v}


def prop(name):
    return [{"Type": "WFPropertyVariableAggrandizement", "PropertyName": name}]


def prop_trunc(prop_name, chars=200):
    """Get a property then take only the first <chars> characters of it."""
    return [
        {"Type": "WFPropertyVariableAggrandizement", "PropertyName": prop_name},
        {
            "Type": "WFGetFirstLastVariableAggrandizement",
            "WFGetFirstLastOrder": "First",
            "WFGetFirstLastCount": ts([str(chars)]),
        },
    ]


# ── UUIDs ──────────────────────────────────────────────────────────────────────
date_id      = uu()   # current date (obtained first)
fdate_id     = uu()   # formatted date dd/MM/yyyy
emails_id    = uu()   # result of mail search
count_id     = uu()   # email count
outer_group  = uu()   # if count != 0 / otherwise / end-if
loop_group   = uu()   # repeat each
loop_id      = uu()   # repeat each action → "Repeat Item"
block_id     = uu()   # single email text block
list_id      = uu()   # retrieved emailList variable
prompt_id    = uu()   # full GPT prompt
gpt_id       = uu()   # ChatGPT response
ntitle_id    = uu()   # note title text
ncontent_id  = uu()   # note body (title line + GPT response)

A = []   # actions list


# ── 1. Get Current Date (used throughout) ─────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.date",
    "WFWorkflowActionParameters": {
        "UUID": date_id,
        "CustomOutputName": "Current Date",
    },
})

# ── 2. Format Date dd/MM/yyyy ──────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.format.date",
    "WFWorkflowActionParameters": {
        "UUID": fdate_id,
        "CustomOutputName": "Formatted Date",
        "WFDateFormatStyle": "Custom",
        "WFDateFormat": "dd/MM/yyyy",
        "WFInput": ref(date_id, "Current Date"),
    },
})

# ── 3. Get Unread Emails (last 24h filter attempted; max 20) ──────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.mail.search",
    "WFWorkflowActionParameters": {
        "UUID": emails_id,
        "CustomOutputName": "Unread Emails",
        "WFMailSearchMaxEmails": 20,
        "WFMailSearchFilter": {
            "WFMailSearchFilterIsRead": False,
        },
    },
})

# ── 4. Count emails ────────────────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.count",
    "WFWorkflowActionParameters": {
        "UUID": count_id,
        "CustomOutputName": "Email Count",
        "Input": ref(emails_id, "Unread Emails"),
    },
})

# ── 5. If count != 0  ── (outer conditional) ──────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
    "WFWorkflowActionParameters": {
        "GroupingIdentifier": outer_group,
        "WFControlFlowMode": 0,          # If
        "WFCondition": 5,                # is not (≠)
        "WFConditionalActionString": "0",
        "WFInput": ref(count_id, "Email Count"),
    },
})

# ── 6. Notify: start processing ───────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.notification",
    "WFWorkflowActionParameters": {
        "WFNotificationActionTitle": "MailOver",
        "WFNotificationActionBody": ts([
            "⏳ Procesando ",
            {"output_uuid": count_id, "output_name": "Email Count"},
            " correos no leídos…",
        ]),
        "WFNotificationActionSound": False,
    },
})

# ── 7. Repeat with Each Email ─────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.repeat.each",
    "WFWorkflowActionParameters": {
        "UUID": loop_id,
        "GroupingIdentifier": loop_group,
        "WFControlFlowMode": 0,
        "WFInput": ref(emails_id, "Unread Emails"),
    },
})

# ── 8. Build email text block (body truncated to ~200 chars) ──────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
    "WFWorkflowActionParameters": {
        "UUID": block_id,
        "CustomOutputName": "Email Block",
        "WFTextActionText": ts([
            "De: ",
            {
                "output_uuid": loop_id,
                "output_name": "Repeat Item",
                "agg": prop("Sender"),
            },
            " | Asunto: ",
            {
                "output_uuid": loop_id,
                "output_name": "Repeat Item",
                "agg": prop("Subject"),
            },
            " | Mensaje: ",
            {
                # Body, then take first 200 chars via chained aggrandizements
                "output_uuid": loop_id,
                "output_name": "Repeat Item",
                "agg": prop_trunc("Body", 200),
            },
            "\n---\n",
        ]),
    },
})

# ── 9. Append block to variable emailList ─────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.appendvariable",
    "WFWorkflowActionParameters": {
        "WFVariableName": "emailList",
        "WFInput": ref(block_id, "Email Block"),
    },
})

# ── 10. End Repeat ────────────────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.repeat.each",
    "WFWorkflowActionParameters": {
        "GroupingIdentifier": loop_group,
        "WFControlFlowMode": 1,
    },
})

# ── 11. Retrieve emailList variable ──────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.getvariable",
    "WFWorkflowActionParameters": {
        "UUID": list_id,
        "CustomOutputName": "Email List",
        "WFVariable": {
            "WFSerializationType": "WFTextTokenAttachment",
            "Value": {"VariableName": "emailList", "Type": "Variable"},
        },
    },
})

# ── 12. Build GPT prompt (4 categories + date + count context) ────────────────
PROMPT_PREFIX = (
    "Hoy es "  # date injected below via token
)
PROMPT_MID = (
    ". Eres un asistente ejecutivo de email. "
    "Analicé "  # count injected below
)
PROMPT_SUFFIX = (
    " correos no leídos.\n"
    "Clasifica cada uno en español usando EXACTAMENTE este formato "
    "(sin texto adicional fuera de él):\n\n"
    "🔴 ACTION ITEMS\n"
    "• [Remitente] Resumen — Acción requerida y plazo si lo hay\n\n"
    "🟡 HIGHLIGHTS\n"
    "• [Remitente] Resumen\n\n"
    "🔵 FYIs\n"
    "• [Remitente] Resumen\n\n"
    "🗑 SKIP\n"
    "• [Remitente] Razón (newsletter, promo, spam, etc.)\n\n"
    "Reglas:\n"
    "- Si una categoría está vacía escribe: (ninguno)\n"
    "- No repitas remitentes si es obvio que son el mismo hilo\n"
    "- Prioriza claridad sobre exhaustividad\n\n"
    "CORREOS:\n"
)

A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
    "WFWorkflowActionParameters": {
        "UUID": prompt_id,
        "CustomOutputName": "Prompt",
        "WFTextActionText": ts([
            PROMPT_PREFIX,
            {"output_uuid": fdate_id, "output_name": "Formatted Date"},
            PROMPT_MID,
            {"output_uuid": count_id, "output_name": "Email Count"},
            PROMPT_SUFFIX,
            {"output_uuid": list_id, "output_name": "Email List"},
        ]),
    },
})

# ── 13. Ask ChatGPT ───────────────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "com.openai.chat.ask-chatgpt-shortcut-action",
    "WFWorkflowActionParameters": {
        "UUID": gpt_id,
        "CustomOutputName": "ChatGPT Response",
        "prompt": ref(prompt_id, "Prompt"),
    },
})

# ── 14. Build Note Title ──────────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
    "WFWorkflowActionParameters": {
        "UUID": ntitle_id,
        "CustomOutputName": "Note Title",
        "WFTextActionText": ts([
            "📬 Briefing ",
            {"output_uuid": fdate_id, "output_name": "Formatted Date"},
            " — ",
            {"output_uuid": count_id, "output_name": "Email Count"},
            " correos",
        ]),
    },
})

# ── 15. Build Note Content (title line + GPT response) ───────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
    "WFWorkflowActionParameters": {
        "UUID": ncontent_id,
        "CustomOutputName": "Note Content",
        "WFTextActionText": ts([
            {"output_uuid": ntitle_id, "output_name": "Note Title"},
            "\n\n",
            {"output_uuid": gpt_id, "output_name": "ChatGPT Response"},
        ]),
    },
})

# ── 16. Create Note in Apple Notes ───────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.addnote",
    "WFWorkflowActionParameters": {
        "WFInput": ref(ncontent_id, "Note Content"),
    },
})

# ── 17. Show final notification (with count) ─────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.notification",
    "WFWorkflowActionParameters": {
        "WFNotificationActionTitle": "MailOver",
        "WFNotificationActionBody": ts([
            "📬 Briefing listo — ",
            {"output_uuid": count_id, "output_name": "Email Count"},
            " correos analizados · revisa Notes",
        ]),
        "WFNotificationActionSound": True,
    },
})

# ── 18. Otherwise: inbox is empty ────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
    "WFWorkflowActionParameters": {
        "GroupingIdentifier": outer_group,
        "WFControlFlowMode": 1,   # Otherwise
    },
})

# ── 19. Show result: inbox clean ─────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.showresult",
    "WFWorkflowActionParameters": {
        "Text": ts(["✅ Inbox limpio — No hay correos sin leer"]),
    },
})

# ── 20. End If ───────────────────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
    "WFWorkflowActionParameters": {
        "GroupingIdentifier": outer_group,
        "WFControlFlowMode": 2,   # End If
    },
})

# ── Assemble Workflow ─────────────────────────────────────────────────────────
workflow = {
    "WFWorkflowActions": A,
    "WFWorkflowClientVersion": "1302.1.3",
    "WFWorkflowHasOutputFallback": False,
    "WFWorkflowIcon": {
        "WFWorkflowIconGlyphNumber": 59511,    # envelope
        "WFWorkflowIconStartColor": 431817727, # dark blue-teal
    },
    "WFWorkflowImportQuestions": [],
    "WFWorkflowInputContentItemClasses": [],
    "WFWorkflowMinimumClientVersionString": "1300",
    "WFWorkflowName": "MailOver Clone",
    "WFWorkflowNoInputBehavior": {"Name": "RunImmediately", "Parameters": {}},
    "WFWorkflowTypes": [],
}

# ── Write output files ────────────────────────────────────────────────────────
OUT = "/home/user/ssssss/MailOverClone_v2.shortcut"
XML = "/home/user/ssssss/MailOverClone_v2.plist"

with open(OUT, "wb") as f:
    plistlib.dump(workflow, f, fmt=plistlib.FMT_BINARY)

with open(XML, "wb") as f:
    plistlib.dump(workflow, f, fmt=plistlib.FMT_XML)

with open(OUT, "rb") as f:
    data = f.read()

sha256 = hashlib.sha256(data).hexdigest()

print(f"Binary : {OUT}")
print(f"XML    : {XML}")
print(f"Size   : {len(data):,} bytes")
print(f"Magic  : {data[:8]}")
print(f"SHA256 : {sha256}")
print(f"Actions: {len(A)}")
for i, a in enumerate(A):
    p = a["WFWorkflowActionParameters"]
    uid = (p.get("UUID") or "")[:8] or "—"
    print(f"  {i+1:2}. {a['WFWorkflowActionIdentifier']}  [{uid}]")
print("Done ✓")
