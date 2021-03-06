# -*- coding: utf-8 -*-
# (c) 2014-2017 Andreas Motl, Elmyra UG <andreas.motl@elmyra.de>

# ==========================================
#               infrastructure
# ==========================================
mongodb-start:
	mongod --dbpath=./var/lib/mongodb/ --smallfiles


# ==========================================
#               prerequisites
# ==========================================

# FPM on the build slave has to be patched:
#
# patch against deb.rb of fpm fame::
#
#   def write_meta_files
#      #files = attributes[:meta_files]
#      files = attributes[:deb_meta_file]



# ==========================================
#             build and release
# ==========================================
#
# Release targets for convenient release cutting.
# Uses the fine ``bumpversion`` utility.
#
# Status: Stable
#
# Synopsis::
#
#    make release bump={patch,minor,major}
#    make python-package
#    make debian-package flavor=daq
#

release: virtualenv bumpversion push

# build and publish python package (sdist)
python-package: sdist publish-sdist

# build and publish debian package with flavor
# Hint: Should be run on an appropriate build slave matching the deployment platform
debian-package: check-flavor-options sdist deb-build-$(flavor) publish-debian
#debian-package-test: check-flavor-options deb-build-$(flavor)


# ==========================================
#                 releasing
# ==========================================
#
# Release targets for convenient release cutting.
#
# Synopsis::
#
#    make release bump={patch,minor,major}
#
# Setup:
#
#    - Make sure you have e.g. ``bumpversion==0.5.3`` in your ``requirements.txt``
#    - Add a ``.bumpversion.cfg`` to your project root properly reflecting
#      the current version and the list of files to bump versions in. Example::
#
#        [bumpversion]
#        current_version = 0.1.0
#        files = doc/source/conf.py
#        commit = True
#        tag = True
#        tag_name = {new_version}
#

bumpversion: check-bump-options
	bumpversion $(bump)

push:
	git push && git push --tags

sdist:
	python setup.py sdist

publish-sdist: sdist
	# publish Python Eggs to eggserver
	# TODO: use localshop or one of its sisters
	rsync -auv --progress ./dist/kotori-*.tar.gz workbench@packages.elmyra.de:/srv/packages/organizations/elmyra/foss/htdocs/python/kotori/

publish-debian:
	# publish Debian packages
	rsync -auv --progress ./dist/kotori*.deb workbench@packages.elmyra.de:/srv/packages/organizations/elmyra/foss/aptly/public/incoming/

check-bump-options:
	@if test "$(bump)" = ""; then \
		echo "ERROR: 'bump' not set, try 'make release bump={patch,minor,major}'"; \
		exit 1; \
	fi

check-flavor-options:
	@if test "$(flavor)" = ""; then \
		echo "ERROR: 'flavor' not set, try 'make debian-package flavor=daq' or 'make debian-package flavor=daq-binary'"; \
		exit 1; \
	fi


# ==========================================
#                packaging
# ==========================================
#
# Makefile-based poor man's version of:
#
#   - https://hynek.me/articles/python-app-deployment-with-native-packages/
#   - https://parcel.readthedocs.org/
#
# Status: Work in progress
#
# Synopsis::
#
#   make deb-build-daq
#   make deb-build-daq-binary
#
# Build package from designated version::
#
#   make deb-build-daq version=0.6.0
#
# List content of package::
#
#   dpkg-deb --contents dist/kotori_0.6.0-1_amd64.deb
#

fpm-options := \
	--name kotori \
	--iteration 1 \
	--deb-user kotori \
	--deb-group kotori \
	--no-deb-use-file-permissions \
	--no-python-obey-requirements-txt \
	--no-python-dependencies \
	--deb-build-depends "pkg-config, gfortran, libatlas-dev, libopenblas-dev, liblapack-dev, libhdf5-dev, libnetcdf-dev, liblzo2-dev, libbz2-dev, libpng12-dev, libfreetype6-dev" \
	--depends python \
	--deb-recommends "influxdb, mosquitto, mosquitto-clients, grafana, mongodb" \
	--deb-suggests "python-scipy, python-numpy, python-matplotlib, fonts-humor-sans" \
	--deb-suggests "python-tables, libatlas3-base, libopenblas-base, liblapack3, libhdf5-8, libhdf5-100, libnetcdfc7, libnetcdf11, liblzo2-2, libbz2-1.0" \
	--provides "kotori" \
	--provides "kotori-daq" \
	--maintainer "andreas.motl@elmyra.de" \
	--license "AGPL 3, EUPL 1.2" \
	--deb-changelog CHANGES.rst \
	--deb-meta-file README.rst \
	--description "Kotori data acquisition, routing and graphing toolkit" \
	--url "https://getkotori.org/"


# get branch and commit identifiers
branch   := $(shell git symbolic-ref HEAD | sed -e 's/refs\/heads\///')
commit   := $(shell git rev-parse --short HEAD)
version  := $(shell python setup.py --version)


deb-build-daq:
	$(MAKE) deb-build name=kotori features=daq,daq_geospatial,export,plotting,firmware,scientific

deb-build-daq-binary:
	$(MAKE) deb-build name=kotori-daq-binary features=daq,daq_binary

deb-build: check-build-options

	# Relative path to build directory
	#$(eval buildpath := "./build/$(name)")

	# Absolute path to build directory
	$(eval buildpath := $(shell readlink -f ./build/$(name)))

	# start super clean, even clear the pip cache
	#rm -rf build dist

	# start clean
	# take care: enable only with caution
	# TODO: sanity check whether buildpath is not empty
	#rm -r $(buildpath) dist

	# prepare
	mkdir -p build dist

	# use "--always copy" to satisfy fpm
	# use "--python=python" to satisfy virtualenv-tools (doesn't grok "python2" when searching for shebangs to replace)
	virtualenv --system-site-packages --always-copy --python=python $(buildpath)

	# Remove superfluous "local" folder inside virtualenv
	# See also:
	# - http://stackoverflow.com/questions/8227120/strange-local-folder-inside-virtualenv-folder
	# - https://github.com/pypa/virtualenv/pull/166
	# - https://github.com/pypa/virtualenv/commit/5cb7cd652953441a6696c15bdac3c4f9746dfaa1
	rm -rf $(buildpath)/local

	# use different directory for temp files, because /tmp usually has noexec attributes
	# otherwise: _cffi_backend.so: failed to map segment from shared object: Operation not permitted
	# TMPDIR=/var/tmp


	# Clean up from previous build

	# Counter "ValueError: bad marshal data (unknown type code)"
	find $(buildpath) -name '*.pyc' -delete

	# 1. Fix shebangs to point back to Python interpreter in virtualenv $(buildpath)/bin/python

	# 1.1 virtualenv/bin/pip
	sed -i -e '1c#!'$(buildpath)'/bin/python' $(buildpath)/bin/pip

	# 1.2 virtualenv/bin/virtualenv-tools
	sed -i -e '1c#!'$(buildpath)'/bin/python' $(buildpath)/bin/virtualenv-tools || true

	# Make sure "virtualenv-tools" is installed into virtualenv
	$(buildpath)/bin/pip install virtualenv-tools==1.0  # --upgrade --force-reinstall

	# 1.3. Fix all other Python entrypoint scripts
	$(buildpath)/bin/virtualenv-tools --update-path=$(buildpath) $(buildpath)


	# 2. Build sdist egg locally
	TMPDIR=/var/tmp $(buildpath)/bin/python setup.py sdist

	# Install package in development mode
	#$(buildpath)/bin/python setup.py install


	# 3. Install from local sdist egg, enabling extra features
	# TODO: Maybe use "--editable" for installing in development mode
	# TODO: Build Wheels: https://pip.pypa.io/en/stable/reference/pip_wheel/
	TMPDIR=/var/tmp $(buildpath)/bin/pip install kotori[$(features)]==$(version) --download-cache=./build/pip-cache --find-links=./dist --process-dependency-links

	# Install from egg on package server
	# https://pip.pypa.io/en/stable/reference/pip_wheel/#cmdoption--extra-index-url
	#TMPDIR=/var/tmp $(buildpath)/bin/pip install kotori[$(features)]==$(version) --process-dependency-links --extra-index-url=https://packages.elmyra.de/elmyra/foss/python/


	# 4. Relocate virtualenv to /opt/kotori
	# Relocate the virtualenv by updating the python interpreter in the shebang of installed scripts.
	# Currently must force reinstall because virtualenv-tools will harm itself (2016-02-21).
	#$(buildpath)/bin/pip install virtualenv-tools==1.0 --upgrade --force-reinstall
	$(buildpath)/bin/virtualenv-tools --update-path=/opt/kotori $(buildpath)


	#rm -f $(buildpath)/{.Python,pip-selfcheck.json}

	# 5. Build Debian package
	fpm \
		-s dir -t deb \
		$(fpm-options) \
		--name $(name) \
		--version $(version) \
		--deb-field 'Branch: $(branch) Commit: $(commit)' \
		--package ./dist/ \
		--config-files "/etc/kotori" \
		--deb-default ./packaging/etc/default \
		--before-install ./packaging/scripts/before-install \
		--after-install ./packaging/scripts/after-install \
		--before-remove ./packaging/scripts/before-remove \
		--verbose \
		--force \
		$(buildpath)/=/opt/kotori \
		./etc/production.ini=/etc/kotori/kotori.ini \
		./etc/examples/=/etc/kotori/examples \
		./packaging/systemd/kotori.service=/usr/lib/systemd/system/kotori.service

#		--debug \


deb-pure: check-build-options
	fpm \
		-s python -t deb \
		$(fpm-options) \
		--python-scripts-executable '/usr/bin/env python' \
		--version $(version) --iteration 1 \
		--depends python \
		--depends python-pip \
		--architecture noarch \
		--verbose \
		--debug \
		--force \
		.

# -------------------------------------------------------------
#   development options on your fingertips (enable on demand)
# -------------------------------------------------------------

# general debugging
#		--debug \

# don't delete working directory (to introspect the cruft in case something went wrong)
		--debug-workspace \

# we don't prefix, instead use the convenient mapping syntax {source}={target}
#		--prefix /opt/kotori \

# we don't set any architecture, let the package builder do it
#		--architecture noarch \

# there are currently just --deb-init and --deb-upstart options for designating an init- or upstart script
# we already use systemd

# Add FILEPATH as /etc/default configuration
#		--deb-default abc \

# amend the shebang of scripts
#	--python-scripts-executable '/usr/bin/env python' \

# Add custom fields to DEBIAN/control file
#		--deb-field 'Branch: master Commit: deadbeef' \


check-build-options:
	@if test "$(version)" = ""; then \
		echo "ERROR: 'version' not set"; \
		exit 1; \
	fi
	@if test "$(name)" = ""; then \
		echo "ERROR: 'name' not set"; \
		exit 1; \
	fi
	@if test "$(features)" = ""; then \
		echo "ERROR: 'features' not set"; \
		exit 1; \
	fi



# ==========================================
#                 environment
# ==========================================
#
# Miscellaneous tools:
# Software tests, Documentation builder, Virtual environment builder
#
test: virtualenv
	@# https://nose.readthedocs.org/en/latest/plugins/doctests.html
	@# https://nose.readthedocs.org/en/latest/plugins/cover.html
	@#export NOSE_IGNORE_FILES="c\.py";
	nosetests --with-doctest --doctest-tests --doctest-extension=rst --verbose \
		kotori/*.py kotori/daq/{application,graphing,services,storage} kotori/daq/intercom/{mqtt/paho.py,strategies.py,udp.py,wamp.py} kotori/firmware kotori/io kotori/vendor/hiveeyes

test-coverage: virtualenv
	nosetests \
		--with-doctest --doctest-tests --doctest-extension=rst \
		--with-coverage --cover-package=kotori --cover-tests \
		--cover-html --cover-html-dir=coverage/html --cover-xml --cover-xml-file=coverage/coverage.xml

docs-html: virtualenv
	touch doc/source/index.rst
	export SPHINXBUILD="`pwd`/.venv27/bin/sphinx-build"; cd doc; make html

virtualenv:
	@test -e .venv27/bin/python || `command -v virtualenv` --python=`command -v python` --no-site-packages .venv27
	@.venv27/bin/pip --quiet install --requirement requirements-dev.txt


# ==========================================
#           ptrace.getkotori.org
# ==========================================

# Don't commit media assets (screenshots, etc.) to the repository.
# Instead, upload them to https://ptrace.getkotori.org/
ptrace_target := root@ptrace.getkotori.org:/srv/www/organizations/daq-tools/ptrace.getkotori.org/htdocs/
ptrace_http   := https://ptrace.getkotori.org/
ptrace: check-ptrace-options
	$(eval prefix := $(shell date --iso-8601))
	$(eval name   := $(shell basename $(source)))
	$(eval id     := $(prefix)_$(name))

	@# debugging
	@#echo "name: $(name)"
	@#echo "id:   $(id)"

	@scp '$(source)' '$(ptrace_target)$(id)'

	$(eval url    := $(ptrace_http)$(id))
	@echo "Access URL: $(url)"

check-ptrace-options:
	@if test "$(source)" = ""; then \
		echo "ERROR: 'source' not set"; \
		exit 1; \
	fi

