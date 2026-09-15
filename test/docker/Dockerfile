# The npm client under test.
#
# Paquette itself runs on the host and this image carries only what a customer's
# machine would have — node, npm, and somewhere to install into. That is the
# point: every other test in this suite builds requests in Ruby and believes its
# own answers, whereas here a real npm resolves, downloads, verifies integrity
# and unpacks, over a real socket, with nothing of Paquette's in the process.
FROM node:22-alpine

# curl so the test can check the registry is reachable before asking npm to use
# it. Without that check a networking failure and a registry bug produce the
# same red test.
RUN apk add --no-cache curl

# npm writes its cache and config under HOME and declines to do some of it as
# root. The node image ships an unprivileged "node" user; the working directory
# has to be created and handed over before switching to it.
RUN mkdir -p /home/node/project && chown -R node:node /home/node

USER node
WORKDIR /home/node/project
