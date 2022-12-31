INSTALL_ROOT?=
INSTALL_PREFIX?=/usr/local

INSTALL_PATH?=${INSTALL_ROOT}${INSTALL_PREFIX}

install:
	install -m 755 maul.rb ${INSTALL_PATH}/bin/maul.rb
	install -m 755 fifo-tee.sh ${INSTALL_PATH}/bin/fifo-tee.sh

uninstall:
	rm -f ${INSTALL_PATH}/bin/maul.rb
	rm -f ${INSTALL_PATH}/bin/fifo-tee.sh
