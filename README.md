Run the latest Ubuntu bootstrap with a cache-busting query parameter:

```bash
bash -c 'curl -fsSL "https://raw.githubusercontent.com/rafael-alani/dotserver/main/linux/ubuntu.sh?nocache=$(date +%s)" | bash'
```
