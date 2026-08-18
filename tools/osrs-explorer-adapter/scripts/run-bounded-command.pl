#!/usr/bin/perl
use strict;
use warnings;
use Errno qw(ESRCH);
use POSIX qw(WEXITSTATUS WIFEXITED WIFSIGNALED WNOHANG WTERMSIG setpgid);

@ARGV >= 2 or exit 64;
my $timeout = shift @ARGV;
$timeout =~ /^\d+$/ && $timeout > 0 or exit 64;

my $child = fork();
defined $child or exit 125;
if ($child == 0) {
    setpgid(0, 0) == 0 or exit 126;
    exec { $ARGV[0] } @ARGV;
    exit 127;
}

setpgid($child, $child);
my $leader_reaped = 0;
my $leader_status = 0;
my $group_exists = sub {
    $! = 0;
    return 1 if kill 0, -$child;
    return 0 if $! == ESRCH;
    return 1;
};
my $poll_leader = sub {
    return if $leader_reaped;
    my $result = waitpid($child, WNOHANG);
    if ($result == $child) {
        $leader_status = $?;
        $leader_reaped = 1;
    } elsif ($result == -1) {
        $leader_reaped = 1;
    }
};
my $quiesce_group = sub {
    kill 'TERM', -$child if $group_exists->();
    for (1 .. 10) {
        $poll_leader->();
        return 1 if $leader_reaped && !$group_exists->();
        select undef, undef, undef, 0.05;
    }
    kill 'KILL', -$child if $group_exists->();
    while (1) {
        $poll_leader->();
        return 1 if $leader_reaped && !$group_exists->();
        select undef, undef, undef, 0.05;
    }
};
my $stop_child = sub {
    my ($exit_code) = @_;
    alarm 0;
    $SIG{HUP} = 'IGNORE';
    $SIG{INT} = 'IGNORE';
    $SIG{TERM} = 'IGNORE';
    $SIG{ALRM} = 'IGNORE';
    $quiesce_group->() or exit 125;
    exit $exit_code;
};

$SIG{HUP} = sub { $stop_child->(129) };
$SIG{INT} = sub { $stop_child->(130) };
$SIG{TERM} = sub { $stop_child->(143) };
$SIG{ALRM} = sub { $stop_child->(124) };
alarm $timeout;

my $waited = waitpid($child, 0);
alarm 0;
$waited == $child or exit 125;
$leader_status = $?;
$leader_reaped = 1;
$quiesce_group->() or exit 125;

exit WEXITSTATUS($leader_status) if WIFEXITED($leader_status);
exit 128 + WTERMSIG($leader_status) if WIFSIGNALED($leader_status);
exit 125;
