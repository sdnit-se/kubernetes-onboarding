FROM docker.io/library/alpine:3
RUN apk add --no-cache curl
# -e plus curl --fail: a DNS, TLS or HTTP error stops the container with a
# non-zero exit, which fails the workflow step instead of printing a result.
CMD ["sh", "-ec", "status=$(curl --fail --silent --show-error --max-time 20 --output /dev/null --write-out '%{http_code}' https://github.com); echo \"Built and ran on $(hostname), $(uname -m); github.com answered HTTP $status\""]
