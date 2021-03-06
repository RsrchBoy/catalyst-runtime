# This test tests the standalone server's auto-restart feature.

use strict;
use warnings;

use Test::More;
BEGIN {
    plan skip_all => 'set TEST_HTTP to enable this test' unless $ENV{TEST_HTTP};
}

use File::Path;
use FindBin;
use LWP::Simple;
use IO::Socket;
use IPC::Open3;
use Time::HiRes qw/sleep/;
eval {require Catalyst::Devel; Catalyst::Devel->VERSION(1.0);};

plan skip_all => 'Catalyst::Devel required' if $@;
plan skip_all => 'Catalyst::Devel >= 1.04 required' if $Catalyst::Devel::VERSION <= 1.03;
eval "use File::Copy::Recursive";
plan skip_all => 'File::Copy::Recursive required' if $@;

my $tmpdir = "$FindBin::Bin/../t/tmp";

# clean up
rmtree $tmpdir if -d $tmpdir;

# create a TestApp and copy the test libs into it
mkdir $tmpdir;
chdir $tmpdir;

system( $^X, "-I$FindBin::Bin/../lib", '-MFile::Spec', '-e', "\@ARGV=('TestApp'); my \$devnull = File::Spec->devnull; open my \$fh, '>', \$devnull or die \"Cannot write to \$devnull: \$!\"; *STDOUT = \$fh; do \"$FindBin::Bin/../script/catalyst.pl\"");

chdir "$FindBin::Bin/..";
File::Copy::Recursive::dircopy( 't/lib', 't/tmp/TestApp/lib' );

# remove TestApp's tests
rmtree 't/tmp/TestApp/t';

# spawn the standalone HTTP server
my $port = 30000 + int rand( 1 + 10000 );

my( $server, $pid );
my @cmd = ($^X, "-I$FindBin::Bin/../lib", "-I$FindBin::Bin/lib",
  "$FindBin::Bin/../t/tmp/TestApp/script/testapp_server.pl", '--port',
  $port, '--restart');

$pid = open3( undef, $server, undef, @cmd )
    or die "Unable to spawn standalone HTTP server: $!";

# switch to non-blocking reads so we can fail
# gracefully instead of just hanging forever

$server->blocking( 0 );

# wait for it to start
print "Waiting for server to start...\n";
while ( check_port( 'localhost', $port ) != 1 ) {
    sleep 1;
}

# change various files
my @files = (
    "$FindBin::Bin/../t/tmp/TestApp/lib/TestApp.pm",
    "$FindBin::Bin/../t/tmp/TestApp/lib/TestApp/Controller/Action/Begin.pm",
    "$FindBin::Bin/../t/tmp/TestApp/lib/TestApp/Controller/Immutable.pm",
    "$FindBin::Bin/../t/tmp/TestApp/lib/TestApp/Controller/Immutable/HardToReload.pm",
);

# change some files and make sure the server restarts itself
NON_ERROR_RESTART:
for ( 1 .. 20 ) {
    my $index = rand @files;
    open my $pm, '>>', $files[$index]
      or die "Unable to open $files[$index] for writing: $!";
    print $pm "\n";
    close $pm;

    # give the server time to notice the change and restart
    my $count = 0;
    my $line;
    while ( ( $line || '' ) !~ /ttempting to restart the server/ ) {
        # wait for restart message
        $line = $server->getline;
        sleep 0.1;
        if ( $count++ > 100 ) {
            fail "Server restarted";
            SKIP: {
                skip "Server didn't restart, no sense in checking response", 1;
            }
            next NON_ERROR_RESTART;
        }
    };
    pass "Server restarted";

    $count = 0;
    while ( check_port( 'localhost', $port ) != 1 ) {
        # wait for it to restart
        sleep 0.1;
        die "Server appears to have died" if $count++ > 100;
    }
    my $response = get("http://localhost:$port/action/default");
    like( $response, qr/Catalyst::Request/, 'Non-error restart, request OK' );

    # give the server some time to reindex its files
    sleep 1;
}

# multiple restart directories

# we need different options so we have to rebuild most
# of the testing environment

kill 'KILL', $pid;
close $server;

# clean up
rmtree "$FindBin::Bin/../t/tmp" if -d "$FindBin::Bin/../t/tmp";

done_testing;

sub check_port {
    my ( $host, $port ) = @_;

    my $remote = IO::Socket::INET->new(
        Proto    => "tcp",
        PeerAddr => $host,
        PeerPort => $port
    );
    if ($remote) {
        close $remote;
        return 1;
    }
    else {
        return 0;
    }
}
