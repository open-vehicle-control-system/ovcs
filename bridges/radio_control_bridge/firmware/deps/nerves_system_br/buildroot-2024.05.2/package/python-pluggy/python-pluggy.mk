################################################################################
#
# python-pluggy
#
################################################################################

PYTHON_PLUGGY_VERSION = 1.4.0
PYTHON_PLUGGY_SOURCE = pluggy-$(PYTHON_PLUGGY_VERSION).tar.gz
PYTHON_PLUGGY_SITE = https://files.pythonhosted.org/packages/54/c6/43f9d44d92aed815e781ca25ba8c174257e27253a94630d21be8725a2b59
PYTHON_PLUGGY_SETUP_TYPE = setuptools
PYTHON_PLUGGY_LICENSE = MIT
PYTHON_PLUGGY_LICENSE_FILES = LICENSE
PYTHON_PLUGGY_DEPENDENCIES = host-python-setuptools-scm
HOST_PYTHON_PLUGGY_DEPENDENCIES = host-python-setuptools-scm

$(eval $(python-package))
$(eval $(host-python-package))
