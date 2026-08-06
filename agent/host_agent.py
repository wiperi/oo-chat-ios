import os
from pathlib import Path

from connectonion import Agent, host


ROOT = Path(__file__).resolve().parent.parent
CO_DIR = Path(
    os.environ.get(
        "CONNECTONION_STATE_DIR",
        str(ROOT / ".runtime" / "hosted-agent"),
    )
)


def create_agent() -> Agent:
    return Agent(
        name="oochatios-hosted-agent",
        model=os.environ.get("CONNECTONION_MODEL", "co/gemini-2.5-pro"),
        system_prompt=(
            "You are a helpful hosted assistant for OOChatIOS. "
            "Answer clearly, state uncertainty, and do not claim actions you did not perform."
        ),
        max_iterations=10,
        co_dir=CO_DIR,
    )


if __name__ == "__main__":
    host(
        create_agent,
        port=int(os.environ.get("CONNECTONION_PORT", "8010")),
        trust=os.environ.get("CONNECTONION_TRUST", "open"),
        co_dir=CO_DIR,
        summary="General-purpose assistant hosted for OOChatIOS.",
        examples=[
            "Explain what you can help me with.",
            "Help me break a problem into clear next steps.",
        ],
    )
