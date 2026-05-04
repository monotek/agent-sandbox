FROM alpine:3.23.4

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add curl git zsh

RUN addgroup -S agent -g 1000 && \
    adduser -S agent -G agent -u 1000 -s /bin/zsh

USER agent:agent

ADD --chown=agent:agent _mise.toml /home/agent/mise.toml

ADD --chown=agent:agent .zshrc /home/agent/.zshrc

WORKDIR /home/agent

RUN curl https://mise.run | zsh && \
    ~/.local/bin/mise trust -ay && \
    ~/.local/bin/mise activate zsh && \
    ~/.local/bin/mise install

ENTRYPOINT ["/bin/zsh"]
