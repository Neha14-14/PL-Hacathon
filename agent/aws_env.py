import os


def load_aws_env(env_file=None):
    if env_file is None:
        base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        env_file = os.path.join(base, "config", "aws_credentials.env")
    if not os.path.exists(env_file):
        return
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                os.environ[key.strip()] = val.strip()
