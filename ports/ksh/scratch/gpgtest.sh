#!/bin/sh
export GNUPGHOME=$HOME/telephone-ksh/gnupg
ls -la "$GNUPGHOME"
gpg --batch --yes --list-keys --with-colons
echo '{"turn":1}' > /tmp/ksh-desc-test
gpg --batch --yes --pinentry-mode loopback --passphrase "" --detach-sign --armor --local-user "libphext telephone ksh" --output /tmp/ksh-desc-test.asc /tmp/ksh-desc-test
echo "gpg rc=$?"
ls -la /tmp/ksh-desc-test.asc 2>/dev/null && head -2 /tmp/ksh-desc-test.asc
