#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y etckeeper git
sed -i -e 's/^#VCS="git"/VCS="git"/' -e 's/^VCS="bzr"/#VCS="bzr"/' -e 's/^GIT_COMMIT_OPTIONS=""/GIT_COMMIT_OPTIONS="-v"/' /etc/etckeeper/etckeeper.conf
etckeeper init 'Initial commit'
etckeeper commit 'Setup etckeeper' || :
sed -i -e 's,//archive\.ubuntu\.com,//jp.archive.ubuntu.com,' /etc/apt/sources.list
sed -i -e 's,//httpredir\.debian\.org,//ftp.jp.debian.org,' /etc/apt/sources.list
etckeeper commit 'Use JP mirror' || :
apt-get update || :
apt-get purge -y nano
apt-get install -y vim
apt-get install -y language-pack-ja || {
  sed -i -e 's/^# ja_JP.UTF-8/ja_JP.UTF-8/' /etc/locale.gen
  locale-gen
}
update-locale LANG=ja_JP.UTF-8
etckeeper commit 'Setup Japanese locale' || :
timedatectl set-timezone Asia/Tokyo || ln -sf ../usr/share/zoneinfo/Asia/Tokyo /etc/localtime
etckeeper commit 'Setup Japanese timezone' || :
if [ ! -f /etc/apt/sources.list.d/milter-manager.list ]; then
  case "$(lsb_release -is)" in
    Debian)
      id=debian
      component=main
      ;;
    Ubuntu)
      id=ubuntu
      component=universe
      ;;
  esac
  {
    echo "deb http://downloads.sourceforge.net/project/milter-manager/$id/stable $(lsb_release -cs) $component"
    echo "deb-src http://downloads.sourceforge.net/project/milter-manager/$id/stable $(lsb_release -cs) $component"
  } >/etc/apt/sources.list.d/milter-manager.list
  apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 1BD22CD1
  etckeeper commit "Add apt-line of milter-manager"
fi
case "$(lsb_release -is)" in
  Debian)
    aptitude update
    aptitude -V -D -y install milter-manager
    aptitude -y purge '~nexim4' postfix+
    aptitude -V -D -y install spamass-milter clamav-milter milter-greylist
    ;;
  Ubuntu)
    apt-get update
    apt-get -V -y install milter-manager
    apt-get -V -y install postfix
    apt-get -V -y install spamass-milter clamav-milter milter-greylist
    ;;
esac
if ! grep -q 'report_safe 0' /etc/spamassassin/local.cf; then
  sed -i -e $'/# report_safe 1/a\\\nreport_safe 0\\\n\\\nremove_header ham Status\\\nremove_header ham Level' /etc/spamassassin/local.cf
fi
if [ -f /lib/systemd/system/spamassassin.service ]; then
  systemctl restart spamassassin.service || :
else
  if grep -q 'ENABLED=0' /etc/default/spamassassin; then
    sed -i -e 's/ENABLED=0/ENABLED=1/' /etc/default/spamassassin
    /etc/init.d/spamassassin start
  fi
fi
if [ -f /etc/default/clamav-milter ]; then
  if grep -q '#SOCKET_RWGROUP=postfix' /etc/default/clamav-milter; then
    sed -i -e 's/#SOCKET_RWGROUP=postfix/SOCKET_RWGROUP=postfix/' /etc/default/clamav-milter
    /etc/init.d/clamav-milter restart
  fi
fi
if egrep '^racl whitelist default' /etc/milter-greylist/greylist.conf; then
  sed -i -e 's/^racl whitelist default/#racl whitelist default\nsubnetmatch \/24\ngreylist 10m\nautowhite 1w\nracl greylist default/' /etc/milter-greylist/greylist.conf
fi
if grep 'ENABLED=0' /etc/default/milter-greylist; then
  sed -i -e 's/ENABLED=0/ENABLED=1\nSOCKET="inet:11125@[127.0.0.1]"/' /etc/default/milter-greylist
  /etc/init.d/milter-greylist start
fi
if grep '# SOCKET_GROUP=postfix' /etc/default/milter-manager; then
  sed -i -e 's/# SOCKET_GROUP=postfix/SOCKET_GROUP=postfix/' -e 's;# CONNECTION_SPEC=unix:/var/spool/postfix/milter-manager/milter-manager\.sock;CONNECTION_SPEC=unix:/var/spool/postfix/milter-manager/milter-manager.sock;' /etc/default/milter-manager
  adduser milter-manager postfix
  /etc/init.d/milter-manager restart
fi
if ! grep -q milter /etc/postfix/main.cf; then
  postconf -e 'milter_protocol = 6'
  postconf -e 'milter_default_action = accept'
  postconf -e 'milter_mail_macros = {auth_author} {auth_type} {auth_authen}'
  postconf -e 'smtpd_milters = unix:/milter-manager/milter-manager.sock'
  /etc/init.d/postfix reload
fi
