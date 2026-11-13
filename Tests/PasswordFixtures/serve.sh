#!/bin/sh
# Serves the sign-in fixtures at http://localhost:$PORT/ (default 8765); the cross-origin frame fixture also uses
# http://127.0.0.1:$PORT/. For a test launch of the app:
#   PLINTH_STORAGE=<throwaway dir> PLINTH_OPEN=http://localhost:8765/plain.html build/Plinth.app/Contents/MacOS/Plinth
# Use a fresh PORT per scenario: the origin includes the port, so earlier saved logins cannot match.
cd "$(dirname "$0")" && exec python3 -m http.server "${PORT:-8765}" --bind 127.0.0.1
