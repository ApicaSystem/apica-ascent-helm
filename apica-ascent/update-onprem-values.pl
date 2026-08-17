#!/usr/bin/env perl
#
# Consumes the default values.yaml and produces example values files
# for on-premises deployments of various sizes. These example files
# are linked from documentation.
#
# Ubuntu users need the libyaml-pp-perl package to run this script.

use strict;
use warnings;
use Storable qw(dclone);
use YAML::PP;
use YAML::PP::Common qw(:PRESERVE);

my $input_file = 'values.yaml';

my $ypp = YAML::PP->new(preserve => PRESERVE_ORDER | PRESERVE_FLOW_STYLE,
                        boolean => 'JSON::PP',
                        header => 0
                        );
my $yaml = $ypp->load_file($input_file);

my @tshirts = qw(single small medium large);

foreach my $size (@tshirts) {
    # Defaults for small deployments
    my $envoy_replicas = 2;
    my $flash_replicas = 2;
    my $flash_ml_replicas = 2;
    my $flash_sync_replicas = 2;
    my $flash_disc_replicas = 2;
    my $coffee_server_replicas = 2;
    my $coffee_worker_replicas = 2;
    my $prometheus_replicas = 2;

    if ($size eq 'medium') {
        $flash_replicas = 4;
        $coffee_worker_replicas = 3;
    } elsif ($size eq 'large') {
        $envoy_replicas = 4;
        $flash_replicas = 8;
        $coffee_worker_replicas = 4;
    }

    my $clone = dclone($yaml); # deep clone to avoid modifying original

    # Global bits
    $clone->{global}{nodePort}{enabled} = $JSON::PP::false;
    $clone->{global}{nodeSelectors}{enabled} = $JSON::PP::false;
    $clone->{global}{persistence}{storageClass} = 'openebs-hostpath';

    # Indicate which values should be set by the operator
    $clone->{global}{domain}                             = '##YOUR_DOMAIN##';
    $clone->{global}{environment}{postgres_password}     = '##YOUR_POSTGRES_PASSWORD##';
    $clone->{global}{environment}{s3_url}                = '##YOUR_S3_URL##';
    $clone->{global}{environment}{s3_access}             = '##YOUR_S3_ACCESS_KEY##';
    $clone->{global}{environment}{s3_secret}             = '##YOUR_S3_ACCESS_SECRET##';
    $clone->{global}{environment}{s3_bucket}             = '##YOUR_S3_BUCKET##';
    $clone->{global}{environment}{s3_region}             = '##YOUR_S3_REGION##';
    $clone->{global}{environment}{AWS_ACCESS_KEY_ID}     = '##YOUR_S3_ACCESS_KEY##';
    $clone->{global}{environment}{AWS_SECRET_ACCESS_KEY} = '##YOUR_S3_ACCESS_SECRET##';
    $clone->{global}{environment}{awsServiceEndpoint}    = '##YOUR_S3_URL##';
    $clone->{global}{environment}{admin_name}            = '##ADMIN_ACCOUNT_NAME##';
    $clone->{global}{environment}{admin_password}        = '##ADMIN_ACCOUNT_PASSWORD##';
    $clone->{global}{environment}{admin_org}             = '##ADMIN_ORGANIZATION##';
    $clone->{global}{environment}{admin_email}           = '##ADMIN_EMAIL##';
    $clone->{postgres}{postgresqlPostgresPassword}       = '##YOUR_POSTGRES_ROOT_PASSWORD##';
    $clone->{postgres}{postgresqlPassword}               = '##YOUR_POSTGRES_PASSWORD##';

    # Kafka client always disabled
    $clone->{'logiq-flash'}{kafka_client}{enabled} = $JSON::PP::false;

    # Set secret names because we don't use Vault
    $clone->{'logiq-flash'}{secrets_name} = 'my-ascent-ingest';
    $clone->{gateway}{tls}{secretName} = 'my-ascent-ingress';

    # Turn off cnpg by default
    $clone->{cnpg}{enabled} = $JSON::PP::false;
    $clone->{cnpg}{backups}{enabled} = $JSON::PP::false;

    # Envoy proxy annotations not needed
    delete $clone->{envoyGateway}{envoyProxy}{provider}{service}{annotations};

    # Restore original prometheus resources
    $clone->{prometheus}{prometheus}{resources}{requests}{memory} = '500Mi';
    $clone->{prometheus}{prometheus}{resources}{limits}{memory}   = '6000Mi';

    # Reduce memory limits for single-node
    if ($size eq 'single') {
        $clone->{postgres}{resources}{limits}{memory}               = '8000Mi';
        $clone->{prometheus}{prometheus}{resources}{limits}{memory} = '2000Mi';
        $clone->{redis}{master}{resources}{limits}{memory}          = '2000Mi';
    }

    $clone->{'logiq-flash'}{replicaCount}     = ($size eq 'single') ? 1 : $flash_replicas;
    $clone->{'logiq-flash'}{replicaCountMl}   = ($size eq 'single') ? 1 : $flash_ml_replicas;
    $clone->{'logiq-flash'}{replicaCountSync} = ($size eq 'single') ? 1 : $flash_sync_replicas;
    $clone->{'flash-discovery'}{replicaCountDiscovery}    = ($size eq 'single') ? 1 : $flash_disc_replicas;
    $clone->{'coffee-server'}{coffee}{replicaCount}        = ($size eq 'single') ? 1 : $coffee_server_replicas;
    $clone->{'coffee-server'}{coffee_worker}{replicaCount} = ($size eq 'single') ? 1 : $coffee_worker_replicas;
    $clone->{prometheus}{prometheus}{replicaCount}        = ($size eq 'single') ? 1 : $prometheus_replicas;
    $clone->{envoyGateway}{envoyProxy}{provider}{deployment}{replicaCount} = ($size eq 'single') ? 1 : $envoy_replicas;

    my $outfile = "values.$size.yaml";
    $ypp->dump_file($outfile, $clone);

    print "Updated $outfile\n";
}

