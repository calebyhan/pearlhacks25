import os
import sys
import pytest

# Ensure server module is importable
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from server import create_app, active_calls, dispatcher_connections


@pytest.fixture(autouse=True)
def clean_state():
    """Reset global state between tests."""
    active_calls.clear()
    dispatcher_connections.clear()
    yield
    active_calls.clear()
    dispatcher_connections.clear()
