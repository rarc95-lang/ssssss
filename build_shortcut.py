#!/usr/bin/env python3
"""
Generate MailOverClone.shortcut
Binary plist (bplist00) compatible with iOS 17+ Shortcuts app.
"""
import plistlib
import uuid
import hashlib

PLACEHOLDER = "￼"  # U+FFFC Object Replacement Character used by Shortcuts for variable slots


def uu():
    return str(uuid.uuid4()).upper()


def ts(parts):
    """
    Build a WFTextTokenString from a list of parts.
    Each part is either:
      - str  → literal text
      - dict → variable reference with keys: output_uuid, output_name, agg (optional list of aggrandizements)
    """
    s = ""
    att = {}
    for p in parts:
        if isinstance(p, str):
            s += p
        else:
            pos = len(s)
            s += PLACEHOLDER
            entry = {
                "OutputUUID": p["output_uuid"],
                "OutputName": p.get("output_name", ""),
                "Type": "ActionOutput",
            }
            if "agg" in p:
                entry["Aggrandizements"] = p["agg"]
            att["{%d, 1}" % pos] = entry
    return {
        "WFSerializationType": "WFTextTokenString",
        "Value": {"string": s, "attachmentsByRange": att},
    }


def ref(uuid_, name="", agg=None):
    """Variable reference as WFTextTokenAttachment (for Input / WFInput fields)."""
    v = {"OutputUUID": uuid_, "OutputName": name, "Type": "ActionOutput"}
    if agg:
        v["Aggrandizements"] = agg
    return {"WFSerializationType": "WFTextTokenAttachment", "Value": v}


def prop(name):
    """Property aggrandizement shorthand."""
    return [{"Type": "WFPropertyVariableAggrandizement", "PropertyName": name}]


# ── UUIDs ──────────────────────────────────────────────────────────────────────
emails_id   = uu()   # output of mail search
count_id    = uu()   # output of count action
cond_group  = uu()   # grouping id for outer if/else/end-if
loop_group  = uu()   # grouping id for repeat each
loop_id     = uu()   # repeat each action output (= current item)
block_id    = uu()   # single email text block
list_id     = uu()   # emailList variable retrieved after loop
prompt_id   = uu()   # full GPT prompt text
gpt_id      = uu()   # ChatGPT response
date_id     = uu()   # current date
fdate_id    = uu()   # formatted date string
ncontent_id = uu()   # final note body (title + response)

A = []  # actions array


# ── 1. Get Unread Emails ───────────────────────────────────────────────────────
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

# ── 2. Count emails ────────────────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.count",
    "WFWorkflowActionParameters": {
        "UUID": count_id,
        "CustomOutputName": "Email Count",
        "Input": ref(emails_id, "Unread Emails"),
    },
})

# ── 3. If count == 0 ──── (WFControlFlowMode 0 = start of if) ─────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
    "WFWorkflowActionParameters": {
        "GroupingIdentifier": cond_group,
        "WFControlFlowMode": 0,     # If
        "WFCondition": 4,           # equals
        "WFConditionalActionString": "0",
        "WFInput": ref(count_id, "Email Count"),
    },
})

# ── 4. Show result: inbox clean ────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.showresult",
    "WFWorkflowActionParameters": {
        "Text": ts(["✅ Inbox limpio — No hay correos sin leer"]),
    },
})

# ── 5. Exit shortcut ───────────────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.exit",
    "WFWorkflowActionParameters": {},
})

# ── 6. End If ─────────────────────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
    "WFWorkflowActionParameters": {
        "GroupingIdentifier": cond_group,
        "WFControlFlowMode": 2,     # End If
    },
})

# ── 7. Repeat with Each Email ─────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.repeat.each",
    "WFWorkflowActionParameters": {
        "UUID": loop_id,
        "GroupingIdentifier": loop_group,
        "WFControlFlowMode": 0,     # start
        "WFInput": ref(emails_id, "Unread Emails"),
    },
})

# ── 8. Build single-email text block ──────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
    "WFWorkflowActionParameters": {
        "UUID": block_id,
        "CustomOutputName": "Email Block",
        "WFTextActionText": ts([
            "De: ",
            {"output_uuid": loop_id, "output_name": "Repeat Item", "agg": prop("Sender")},
            " | Asunto: ",
            {"output_uuid": loop_id, "output_name": "Repeat Item", "agg": prop("Subject")},
            " | Mensaje: ",
            {"output_uuid": loop_id, "output_name": "Repeat Item", "agg": prop("Body")},
            "\n\n",
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
        "WFControlFlowMode": 1,     # end
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

# ── 12. Build GPT prompt ──────────────────────────────────────────────────────
PROMPT_PREFIX = (
    "Eres un asistente ejecutivo de email. Clasifica estos correos "
    "en español en tres categorías con este formato exacto:\n\n"
    "🔴 ACTION ITEMS\n"
    "• [Remitente] Resumen — Acción requerida\n\n"
    "🟡 HIGHLIGHTS\n"
    "• [Remitente] Resumen\n\n"
    "🔵 FYIs\n"
    "• [Remitente] Resumen\n\n"
    "Si una categoría está vacía escribe: (ninguno)\n"
    "No agregues texto fuera de este formato.\n\n"
    "CORREOS:\n"
)

A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
    "WFWorkflowActionParameters": {
        "UUID": prompt_id,
        "CustomOutputName": "Prompt",
        "WFTextActionText": ts([
            PROMPT_PREFIX,
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

# ── 14. Get Current Date ──────────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.date",
    "WFWorkflowActionParameters": {
        "UUID": date_id,
        "CustomOutputName": "Current Date",
    },
})

# ── 15. Format Date as dd/MM/yyyy ─────────────────────────────────────────────
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

# ── 16. Build note content (title as first line, then body) ──────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
    "WFWorkflowActionParameters": {
        "UUID": ncontent_id,
        "CustomOutputName": "Note Content",
        "WFTextActionText": ts([
            "📬 Briefing ",
            {"output_uuid": fdate_id, "output_name": "Formatted Date"},
            "\n\n",
            {"output_uuid": gpt_id, "output_name": "ChatGPT Response"},
        ]),
    },
})

# ── 17. Create Note in Apple Notes ───────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.addnote",
    "WFWorkflowActionParameters": {
        "WFInput": ref(ncontent_id, "Note Content"),
    },
})

# ── 18. Show Notification ─────────────────────────────────────────────────────
A.append({
    "WFWorkflowActionIdentifier": "is.workflow.actions.notification",
    "WFWorkflowActionParameters": {
        "WFNotificationActionTitle": "MailOver",
        "WFNotificationActionBody": "📬 Briefing listo — revisa Notes",
        "WFNotificationActionSound": True,
    },
})

# ── Assemble Workflow ─────────────────────────────────────────────────────────
workflow = {
    "WFWorkflowActions": A,
    "WFWorkflowClientVersion": "1302.1.3",
    "WFWorkflowHasOutputFallback": False,
    "WFWorkflowIcon": {
        "WFWorkflowIconGlyphNumber": 59511,    # envelope glyph
        "WFWorkflowIconStartColor": 463140863, # blue
    },
    "WFWorkflowImportQuestions": [],
    "WFWorkflowInputContentItemClasses": [],
    "WFWorkflowMinimumClientVersionString": "1300",
    "WFWorkflowName": "MailOver Clone",
    "WFWorkflowNoInputBehavior": {
        "Name": "RunImmediately",
        "Parameters": {},
    },
    "WFWorkflowTypes": [],
}

# ── Write binary plist ────────────────────────────────────────────────────────
OUT = "/home/user/ssssss/MailOverClone.shortcut"
XML = "/home/user/ssssss/MailOverClone.plist"

with open(OUT, "wb") as f:
    plistlib.dump(workflow, f, fmt=plistlib.FMT_BINARY)

with open(XML, "wb") as f:
    plistlib.dump(workflow, f, fmt=plistlib.FMT_XML)

with open(OUT, "rb") as f:
    data = f.read()

sha256 = hashlib.sha256(data).hexdigest()
sha1   = hashlib.sha1(data).hexdigest()

print(f"Binary shortcut : {OUT}")
print(f"XML plist copy  : {XML}")
print(f"File size       : {len(data):,} bytes")
print(f"Magic bytes     : {data[:8]}")
print(f"SHA-256         : {sha256}")
print(f"SHA-1           : {sha1}")
print(f"Actions count   : {len(A)}")
print("Done ✓")
