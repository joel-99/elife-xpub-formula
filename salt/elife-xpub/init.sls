{% set docker_compose = 'docker-compose -f docker-compose.yml -f docker-compose.formula.yml' %}

elife-xpub-repository:
    builder.git_latest:
        - name: git@github.com:elifesciences/elife-xpub-deployment.git
        - identity: {{ pillar.elife.projects_builder.key or '' }}
        - rev: {{ salt['elife.rev']() }}
        - branch: {{ salt['elife.branch']() }}
        - target: /srv/elife-xpub/
        - force_fetch: True
        - force_checkout: True
        - force_reset: True

    file.directory:
        - name: /srv/elife-xpub
        - user: {{ pillar.elife.deploy_user.username }}
        - group: {{ pillar.elife.deploy_user.username }}
        - recurse:
            - user
            - group
        - require:
            - builder: elife-xpub-repository

elife-xpub-logs:
    file.directory:
        - name: /srv/elife-xpub/var/logs/
        - user: {{ pillar.elife.deploy_user.username }}
        - group: {{ pillar.elife.deploy_user.username }}
        - makedirs: True
        - dir_mode: 775
        - require:
            - elife-xpub-repository

elife-xpub-environment-variables-for-configuration:
    file.managed:
        - name: /etc/profile.d/elife-xpub-configuration.sh
        - contents: |
            export ORCID_CLIENT_ID={{ pillar.elife_xpub.orcid.client_id }}
            export ORCID_CLIENT_SECRET={{ pillar.elife_xpub.orcid.client_secret }}
            export PUBSWEET_BASEURL={{ pillar.elife_xpub.pubsweet.base_url }}
            export PUBSWEET_SECRET={{ pillar.elife_xpub.pubsweet.secret }}
            export S3_BUCKET={{ pillar.elife_xpub.s3.bucket }}
            export NODE_CONFIG_ENV={{ pillar.elife_xpub.deployment_target }}
            export MECA_SFTP_HOST={{ pillar.elife_xpub.meca.sftp.connection.host }}
            export MECA_SFTP_PORT={{ pillar.elife_xpub.meca.sftp.connection.port }}
            export MECA_SFTP_USERNAME={{ pillar.elife_xpub.meca.sftp.connection.username }}
            export MECA_SFTP_PASSWORD={{ pillar.elife_xpub.meca.sftp.connection.password }}
            export MECA_SFTP_REMOTEPATH={{ pillar.elife_xpub.meca.sftp.remote_path }}
            export MECA_API_KEY={{ pillar.elife_xpub.meca.api_key }}
            export NEW_RELIC_ENABLED={% if pillar.elife.newrelic.enabled %}true{% else %}false{% endif %}
            export NEW_RELIC_APP_NAME={{ salt['elife.cfg']('project.stackname') }}
            export NEW_RELIC_LICENSE_KEY={{ pillar.elife.newrelic.license }}

elife-xpub-environment-variables-for-database-credentials:
    file.managed:
        - name: /etc/profile.d/elife-xpub-database-credentials.sh
        - contents: |
            {% if salt['elife.cfg']('cfn.outputs.RDSHost') %}
            # remote RDS server
            export PGHOST={{ salt['elife.cfg']('cfn.outputs.RDSHost') }}
            export PGPORT={{ salt['elife.cfg']('cfn.outputs.RDSPort') }}
            export PGDATABASE={{ salt['elife.cfg']('project.rds_dbname') }}
            export PGUSER={{ salt['elife.cfg']('project.rds_username') }}
            export PGPASSWORD={{ salt['elife.cfg']('project.rds_password') }}
            {% else %}
            # local container
            export PGHOST=postgres
            export PGPORT=5432
            export PGDATABASE=xpub
            export PGUSER=xpub
            export PGPASSWORD=
            {% endif %}

elife-xpub-database-startup:
    cmd.run:
        - name: |
            {% if salt['elife.cfg']('cfn.outputs.RDSHost') %}
            # remote RDS server
            echo "RDS instance should already be started"
            {% else %}
            {{ docker_compose }} up -d postgres
            {% endif %}
        - user: {{ pillar.elife.deploy_user.username }}
        - cwd: /srv/elife-xpub
        - require:
            - elife-xpub-repository
            - elife-xpub-environment-variables-for-configuration
            - elife-xpub-environment-variables-for-database-credentials

elife-xpub-database-available:
    cmd.run:
        - name: |
            # NOTE: var expansion happens on the host not in the container
            {{ docker_compose }} run app /bin/bash -c "timeout 10 bash -c 'until echo > /dev/tcp/${PGHOST}/${PGPORT} ; do sleep 1 ;done' "
        - user: {{ pillar.elife.deploy_user.username }}
        - cwd: /srv/elife-xpub
        - require:
            - elife-xpub-database-startup

elife-xpub-database-setup:
    cmd.script:
        - name: salt://elife-xpub/scripts/setup-database.sh
        - template: jinja
        - user: {{ pillar.elife.deploy_user.username }}
        - cwd: /srv/elife-xpub
        - require:
            - elife-xpub-database-available

elife-xpub-docker-compose:
    cmd.run:
        - name: {{ docker_compose }} up -d --force-recreate
        - user: {{ pillar.elife.deploy_user.username }}
        - cwd: /srv/elife-xpub
        - require:
            - elife-xpub-repository
            - elife-xpub-database-setup

elife-xpub-service-ready:
    cmd.run:
        - name: docker wait xpub_bootstrap_1
        - user: {{ pillar.elife.deploy_user.username }}
        - require:
            - elife-xpub-docker-compose

elife-xpub-nginx-vhost:
    file.managed:
        - name: /etc/nginx/sites-enabled/xpub.conf
        - source: salt://elife-xpub/config/etc-nginx-sites-enabled-xpub.conf
        - template: jinja
        - require:
            - nginx-config
            - elife-xpub-service-ready
        - listen_in:
            - service: nginx-server-service

# frees disk space from old images/containers/volumes/...
elife-xpub-docker-prune:
    cmd.run:
        - name: /usr/local/docker-scripts/docker-prune
        - require:
            - docker-ready

elife-xpub-syslog-ng:
    file.managed:
        - name: /etc/syslog-ng/conf.d/elife-xpub.conf
        - source: salt://elife-xpub/config/etc-syslog-ng-conf.d-elife-xpub.conf
        - template: jinja
        - require:
            - pkg: syslog-ng
            - elife-xpub-logs
        - listen_in:
            - service: syslog-ng

elife-xpub-logrotate:
    file.managed:
        - name: /etc/logrotate.d/elife-xpub
        - source: salt://elife-xpub/config/etc-logrotate.d-elife-xpub
        - template: jinja
        - require:
            - elife-xpub-logs
