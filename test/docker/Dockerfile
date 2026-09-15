# The npm client under test; Paquette itself runs on the host.
FROM node:22-alpine

# curl, so the test can tell a networking failure from a registry bug.
RUN apk add --no-cache curl

# npm declines some cache/config writes as root.
RUN mkdir -p /home/node/project && chown -R node:node /home/node

USER node
WORKDIR /home/node/project
