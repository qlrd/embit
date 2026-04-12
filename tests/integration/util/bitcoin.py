import subprocess
import os
import sys
import time
import shutil

from .rpc import BitcoinRPC

EMBIT_TEMP_DIR = os.environ.get("EMBIT_TEMP_DIR")
if not EMBIT_TEMP_DIR:
    print("EMBIT_TEMP_DIR is not set. Use tests/run.sh.")
    sys.exit(1)


class Bitcoind:
    datadir = os.path.join(EMBIT_TEMP_DIR, "data", "bitcoin", "chain")
    rpcport = 18778
    port = 18779
    rpcuser = "bitcoin"
    rpcpassword = "secret"
    name = "Bitcoin Core"
    binary = os.path.join(EMBIT_TEMP_DIR, "binaries", "bitcoind")

    def __init__(self):
        self._rpc = None
        self._address = None
        self.proc = None

    @property
    def address(self):
        if self._address is None:
            self._address = self.rpc.getnewaddress(wallet="")
        return self._address

    @property
    def cmd(self):
        return f"{self.binary} -datadir={self.datadir} -regtest -fallbackfee=0.0001 -rpcuser={self.rpcuser} -rpcpassword={self.rpcpassword} -rpcport={self.rpcport} -port={self.port}"

    @property
    def rpc(self):
        if self._rpc is None:
            self._rpc = BitcoinRPC(self.rpcuser, self.rpcpassword, port=self.rpcport)
        return self._rpc

    def wallet(self, wname=""):
        return self.rpc.wallet(wname)

    def start(self):
        print(f"Starting {self.name} in regtest mode with datadir {self.datadir}")
        try:
            shutil.rmtree(self.datadir)
        except:
            pass
        try:
            os.makedirs(self.datadir)
        except:
            pass
        import shlex

        self.proc = subprocess.Popen(
            shlex.split(self.cmd),
            start_new_session=True,
        )
        self._wait_for_rpc()
        self.get_coins()

    def _wait_for_rpc(self, timeout=30):
        """Poll RPC until it responds or timeout."""
        for _ in range(timeout * 2):
            try:
                self.rpc.getblockchaininfo()
                return
            except Exception:
                time.sleep(0.5)
        raise RuntimeError(f"{self.name} RPC not ready after {timeout}s")

    def get_coins(self):
        # create default wallet
        if "" not in self.rpc.listwallets():
            # createwallet(name, disable_private_keys, blank, passphrase, avoid_reuse, descriptors)
            self.rpc.createwallet("", False, False, "", False, True)
        self.mine(101)
        assert self.rpc.getbalance(wallet="") > 0

    def mine(self, n=1):
        self.rpc.generatetoaddress(n, self.address)

    def stop(self):
        print(f"Shutting down {self.name}")
        try:
            self.rpc.stop()
        except Exception as e:
            print(
                f"Note: RPC stop failed for {self.name} ({e!r}); waiting on process.",
                file=sys.stderr,
            )
        if self.proc is None or self.proc.poll() is not None:
            return
        try:
            self.proc.wait(timeout=120)
        except subprocess.TimeoutExpired:
            print(
                f"{self.name} still running after 120s; sending SIGKILL",
                file=sys.stderr,
            )
            self.proc.kill()
            self.proc.wait(timeout=30)


daemon = Bitcoind()
