FROM docker.io/library/alpine:3
RUN apk add --no-cache curl
CMD ["sh", "-c", "echo \"Built and ran on $(hostname), $(uname -m), $(curl -s -o /dev/null -w 'internet %{http_code}' https://github.com)\""]
