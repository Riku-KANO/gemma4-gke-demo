import datetime
import os

import httpx
from google.adk.agents import LlmAgent
from google.adk.models.lite_llm import LiteLlm


MODEL_ID_SMALL = os.environ["MODEL_ID_SMALL"]
MODEL_ID_LARGE = os.environ["MODEL_ID_LARGE"]
GATEWAY_URL = os.environ["GATEWAY_URL"]  # e.g. http://<gw-ip>/v1


def get_current_time(timezone: str = "UTC") -> dict:
    """Return the current UTC time as an ISO-8601 string.

    Args:
        timezone: The timezone label to echo back. The clock always reads UTC.
    """
    return {
        "time": datetime.datetime.utcnow().isoformat() + "Z",
        "tz": timezone,
    }


def calculator(expression: str) -> dict:
    """Evaluate a basic arithmetic expression.

    Args:
        expression: Arithmetic expression using digits and + - * / ( ) . only.
    """
    allowed = set("0123456789+-*/(). ")
    if not set(expression) <= allowed:
        return {"error": "invalid characters; only digits and + - * / ( ) . are allowed"}
    try:
        value = eval(expression, {"__builtins__": {}}, {})
    except Exception as exc:
        return {"error": f"evaluation failed: {exc}"}
    return {"expression": expression, "result": value}


def consult_expert(question: str) -> dict:
    """Forward a hard question to the larger Gemma model for deeper reasoning.

    Use this when the user asks for analysis, multi-step reasoning, code
    review, or a long-form explanation — anything the small orchestrator
    model cannot handle well. Return the expert's answer verbatim.

    Args:
        question: The full question to pass to the expert model.
    """
    system_prompt = (
        # Intentionally long-ish (>1KB) so that repeated expert consultations
        # in the same session share a prefix. GKE Inference Gateway's
        # prefix-cache-aware routing will then pin follow-ups to the same
        # replica, landing cache hits on vLLM's --enable-prefix-caching.
        "You are the Expert Reasoner, a careful and thorough assistant that "
        "specializes in multi-step analysis, code review, mathematical "
        "reasoning, and clear long-form explanations. When answering:\n"
        "  1. Start by restating the user's question in one sentence.\n"
        "  2. Break the problem down into 3-5 numbered steps.\n"
        "  3. Work through each step, showing intermediate reasoning.\n"
        "  4. Finish with a single short 'Answer:' line.\n"
        "Prefer clarity over brevity. Never guess — say 'I don't know' if "
        "you are not certain.\n"
        "Always respond in the same language as the user."
    )
    try:
        resp = httpx.post(
            f"{GATEWAY_URL}/chat/completions",
            json={
                "model": MODEL_ID_LARGE,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": question},
                ],
                "max_tokens": 512,
                "temperature": 0.2,
            },
            timeout=120.0,
        )
        resp.raise_for_status()
        data = resp.json()
        return {
            "model": MODEL_ID_LARGE,
            "answer": data["choices"][0]["message"]["content"],
        }
    except Exception as exc:
        return {"error": f"expert call failed: {exc}"}


root_agent = LlmAgent(
    name="gemma_demo_agent",
    model=LiteLlm(
        model=f"openai/{MODEL_ID_SMALL}",
        api_base=GATEWAY_URL,
        api_key="not-needed",
    ),
    instruction=(
        "You are a fast orchestrator agent running on a small Gemma model. "
        "You have three tools:\n"
        "  - get_current_time: for clock / date questions.\n"
        "  - calculator: for arithmetic.\n"
        "  - consult_expert: for any question requiring multi-step reasoning, "
        "analysis, code review, or long-form explanation.\n"
        "Rules:\n"
        "  1. For simple factual or arithmetic questions answer directly or "
        "use get_current_time / calculator.\n"
        "  2. For anything non-trivial, call consult_expert and return its "
        "answer verbatim.\n"
        "  3. Do not attempt to reason deeply yourself — you are the router, "
        "not the reasoner.\n"
        "Always respond in the same language as the user."
    ),
    tools=[get_current_time, calculator, consult_expert],
)
