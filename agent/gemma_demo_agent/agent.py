import datetime
import os

from google.adk.agents import LlmAgent
from google.adk.models.lite_llm import LiteLlm


def get_current_time(timezone: str = "UTC") -> dict:
    """Return the current UTC time as an ISO-8601 string.

    Args:
        timezone: The timezone label to echo back. Only the label is returned;
            the clock always reads UTC.
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


MODEL_ID = os.environ["MODEL_ID"]
API_BASE = os.environ["GATEWAY_URL"]

root_agent = LlmAgent(
    name="gemma_demo_agent",
    model=LiteLlm(
        model=f"openai/{MODEL_ID}",
        api_base=API_BASE,
        api_key="not-needed",
    ),
    instruction=(
        "You are a helpful assistant running on a self-hosted Gemma model. "
        "When the user asks for the current time or an arithmetic result, "
        "call the appropriate tool instead of guessing."
    ),
    tools=[get_current_time, calculator],
)
