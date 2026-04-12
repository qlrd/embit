# this should run with python3
import sys

if sys.implementation.name == "micropython":
    print("This file should run with python3, not micropython!")
    sys.exit(1)

from util.bitcoin import daemon as bitcoind
from util.liquid import daemon as elementsd
import unittest


def main():
    try:
        bitcoind.start()
        elementsd.start()
        result = unittest.main("tests", exit=False)
        if not result.result.wasSuccessful():
            sys.exit(1)
    finally:
        elementsd.stop()
        bitcoind.stop()


if __name__ == "__main__":
    main()
