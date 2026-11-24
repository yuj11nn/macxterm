#!/bin/sh
# SSH_ASKPASS-хелпер: делегирует в основной бинарник, который читает секрет из Keychain.
exec "$(dirname "$0")/../MacOS/MacXterm" --askpass "$@"
