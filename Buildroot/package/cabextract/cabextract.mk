###########################################################
#
# cabextract
#
###########################################################

# https, not http: the plain-HTTP fetch is the one that gets dropped by
# corporate egress filtering, and it is also what timed out on GitHub's runners.
#
# This host is the only site Buildroot will try for this package -- a package
# gets exactly one _SITE -- and it is not dependable. build.sh seeds the
# download directory from a list of mirrors before Buildroot ever looks at it;
# see seedCabextract() there, and cabextract.hash for what makes that safe.
CABEXTRACT_SITE=https://www.cabextract.org.uk
CABEXTRACT_VERSION=1.11
CABEXTRACT_SOURCE=cabextract-$(CABEXTRACT_VERSION).tar.gz
CABEXTRACT_CONF_OPTS=ac_cv_func_fnmatch_gnu=yes ac_cv_func_fnmatch_works=yes

$(eval $(autotools-package))
