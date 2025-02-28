.. _nixos-lamp:

LAMP (Apache/mod_php)
=====================

The LAMP role starts a managed instance of Apache with ``mod_php`` that can be
used to easily run a production-ready PHP application server.

.. note::

	The Apache configured by this role does not bind / open firewall ports to the
	frontend network automatically. It is not intended to serve applications
	directly to consumers but should be placed behind a :ref:`webgateway
	<nixos-webgateway>`.

Configuration
-------------

This role is configured exclusively using NixOS configuration options. It can
provide multiple applications by setting up multiple vhosts and you can put the
configuration in a single file or distribute it over multiple files depending on
your use case.

As a service user, place a file in :file:`/etc/local/nixos/{myservice}.nix`:

A complete configuration might looks something like this:

.. code-block:: Nix

	{ pkgs, ... }:

	{

	  flyingcircus.roles.lamp = {

	    vhosts = [
	      { port = 8000;
	        docroot = "/srv/s-myserviceuser/application.git/docroot";
	      }
	    ];

	    php = pkgs.lamp_php74;

	    apache_conf = ''
	      MaxRequestWorkers 5
	    '';

	    php_ini = ''
	      ; max filesize
	      upload_max_filesize = 200M
	      post_max_size = 200M


	      date.timezone = Europe/Berlin

	      session.save_handler = redis
	      session.save_path = "tcp://myservice01:6379?auth=<secret>"
	    '';

	  };
	}


``flyingcircus.roles.lamp.vhost`` (required)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The vhost configuration allows you to configure multiple applications per VM
each running on a separate port. The two options for every vhost thus are:

``port``
	The port number that Apache should listen on for this application.
	We recommend starting with 8000 and counting up from there.

``docroot``
	The absolute path to the docroot of your application.

``flyingcircus.roles.lamp.apache_conf`` (optional)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Any text written here will be included in the global Apache configuration. Use
this to adjust global settings like workers:


.. code-block:: ApacheConf

	MaxRequestWorkers 5

Note that if you distribute your configuration over multiple files then you
can repeat this option and the values will be concatenated to a single big
Apache config file. They will also always apply to all vhosts.


``flyingcircus.roles.lamp.php`` (optional)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A reference to a PHP package that will be used in Apache and in the
CLI. 

Supported packages:

* ``pkgs.lamp_php56`` (outdated but provided for legacy applications)
* ``pkgs.lamp_php73``
* ``pkgs.lamp_php74``

You can also use any custom PHP package from the NixOS universe (if you
know what you are doing. ;) )


``flyingcircus.roles.lamp.tideways_api_key`` (optional)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

If you have an account with tideways.com then you can quickly enable the 
tideways profiler for your application by setting the API key here:

.. code-block:: Nix

	flyingcircus.roles.lamp.tideways_api_key = "my-api-key";


``flyingcircus.roles.lamp.php_ini`` (optional)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

We deliver a production-tested PHP configuration that you can extend by placing
additional configuration instructions in this option:

.. code-block:: INI

	; max filesize
	upload_max_filesize = 200M
	post_max_size = 200M

Similar to the ``flyingcircus.roles.lamp.apache_conf`` option this will 
be concatenated with from all Nix configuration files with our global platform
settings and will be applied to all vhosts.

PHP version and modules
~~~~~~~~~~~~~~~~~~~~~~~

We currently provide a single pre-selected version of PHP (7.3) with a fixed set
of modules. Please contact our support if you need a different version of PHP
and/or further modules. 

Interaction
-----------

No special interaction is required. Changes to the configuration need to be
activated as usual using:

.. code-block:: console

	$ sudo fc-manage -b

Network
-------

The Apache server listens on the :ref:`srv interface <logical_networks>` only.

Security
--------

* Apache runs in a separate user who is a member of the ``service`` group and 
  thus can (by default) access files owned by service users.

* Access is read-only for Apache by default, but you can grant write access for
  directories by running :command:``chmod g+rwsx`` on the directory.

Debugging
---------

To assist with debugging we have integrated the `Tideways application performance monitoring <https://tideways.com/>`_ daemon and PHP module by default.

To enable it, you just have to place your Tideways API key in :file:`/etc/local/lamp/php.ini`:

.. code-block:: console

   $ echo "tideways.api_key=<secretapikey>" >> /etc/local/lamp/php.ini
   $ sudo fc-manage -b

Logging
-------

Apache logs are available in :file:`/var/log/httpd`.

PHP output is accessible through the journal, running :command:`journalctl -t php -t httpd`.


Monitoring
----------

Our platform monitoring checks that Apache is running (through systemd) and verifies that the Apache statuspage (mod_status accessible via :command:`curl http://localhost:8001/server-status`) is available.
