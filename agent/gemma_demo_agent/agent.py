import ast
import datetime
import operator
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


_CALC_BINOPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.FloorDiv: operator.floordiv,
    ast.Mod: operator.mod,
}
_CALC_UNARYOPS = {ast.UAdd: operator.pos, ast.USub: operator.neg}


def _calc_eval(node: ast.AST) -> float:
    # Walk a parsed expression tree, permitting only numeric literals and the
    # four basic binary ops plus unary +/-. Exponentiation (`**`) is
    # intentionally excluded because model-generated input could otherwise
    # burn CPU on things like `9**9**9`.
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return node.value
    if isinstance(node, ast.UnaryOp) and type(node.op) in _CALC_UNARYOPS:
        return _CALC_UNARYOPS[type(node.op)](_calc_eval(node.operand))
    if isinstance(node, ast.BinOp) and type(node.op) in _CALC_BINOPS:
        return _CALC_BINOPS[type(node.op)](_calc_eval(node.left), _calc_eval(node.right))
    raise ValueError(f"disallowed syntax: {type(node).__name__}")


def calculator(expression: str) -> dict:
    """Evaluate a basic arithmetic expression.

    Args:
        expression: Arithmetic expression using digits and + - * / % // ( ) . only.
            Exponentiation is not supported (it's an easy CPU DoS vector
            when an LLM is generating the input).
    """
    try:
        tree = ast.parse(expression, mode="eval")
        value = _calc_eval(tree.body)
    except (SyntaxError, ValueError, ZeroDivisionError, OverflowError) as exc:
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
