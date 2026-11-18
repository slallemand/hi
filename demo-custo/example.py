import ctypes
import platform
import sys


def main():
    print("=== Runtime Hardened Image ===")
    print("Hello from a customized Hardened Image!")
    print(f"Python {sys.version.split()[0]} on {platform.system()} {platform.machine()}")

    # Test dynamique de la bibliothèque C libpq injectée via chunkah
    try:
        libpq = ctypes.cdll.LoadLibrary("libpq.so.5")
        print(f"[OK] Dynamic library libpq loaded successfully -> {libpq}")
    except OSError as err:
        print(f"[ERR] Failed to load libpq: {err}")


if __name__ == "__main__":
    main()
