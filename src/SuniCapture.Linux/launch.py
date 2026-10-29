import sys

try:
    from sunicapture.app import main
except ImportError as error:
    print("SuniCapture needs the Linux GTK, Cairo and GStreamer Python bindings. See docs/linux.md for installation instructions.", file=sys.stderr)
    print(str(error), file=sys.stderr)
    raise SystemExit(1)

raise SystemExit(main())
