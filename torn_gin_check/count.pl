use strict;
use warnings;
use DBI;
use IO::Pipe;
use Storable;
use Data::Dumper;
use List::Util qw(shuffle);
use Digest::MD5 qw(md5_hex);

## This is a stress tester for PostgreSQL crash recovery.

## It spawns a number of processes which all connect to the database
## and madly update a table until either the server crashes, or
## for a million updates (per process).

## Upon crash, each Perl process reports up to the parent how many times each value was updated
## plus which update was 'in flight' at the time of the crash. (Since we received neither an
## error nor a confirmation, the proper status of this in-flight update is unknowable)

## The parent consolidates this info, waits for the database to recover, and verifies
## that the state of the database matches what we know it ought to be.

## first arg is number of processes (default 4), 2nd is number of updates per process
## (default 1_000_000), 3rd argument causes aborts when a certain discrepancy is seen

## Arranging for the server to crash is the obligation of the outer driving script (do.sh)
## and the accompanying instrumentation patch.

## I invoke this in an outer driving script and let both the Perl messages and the
## postmaster logs spool together into one log file.  That way it is easier to correlate
## server events with the client/Perl events chronologically.

## This generates a lot of logging info.  The tension here is that if you generate too much
## info, it is hard to find anomalies in the log file.  But if you generate too little info,
## then once you do find anomalies you can't figure out the cause.  So I error on the side
## of logging too much, and use command lines (memorialized below) to pull out the most
## interesting things.

## But with really high logging, the lines in the log file start
## getting garbled up, so back off a bit.  The commented out warn and elog things in this file
## and the patch file show places where I previously needed logging for debugging specific things,
## but decided I don't need it all of the time.  Leave the commented code as landmark for the future.

## look for odd messages in log file that originate from Perl
#fgrep ' line ' do.out |sort|uniq -c|sort -n|fgrep -v 'in flight'

## look at rate of incrementing over time, for Excel or SpotFire.
#grep -P '2014-05|^sum ' do.out |grep -P '^sum' -B1|perl -ne 'my @x=split/PDT/; print $x[0] and next if @x>1; print if /sum/' > ~/jj.txt

my $SIZE=10_000;

## centralize connections to one place, in case we want to point to a remote server or use a password
sub dbconnect {
  my $dbh = DBI->connect("dbi:Pg:", "", "", {AutoCommit => 1, RaiseError=>1, PrintError=>0});
  return $dbh;
};

my %count;

while (1) {
  %count=();
  eval {
    my $dbh = dbconnect();
    eval { ## on multiple times through, the table already exists, just let it fail
         ## But if the table exists, don't pollute the log with errors
         ($dbh->selectrow_array("select count(*) from pg_tables where tablename='foo';"))[0] == 1 and return;
         $dbh->do(<<'END');
create table foo(index int, count int, text_array text[]);
create unique index on foo(index);
create index on foo using gin (text_array);
END
    };
    my $dat = $dbh->selectall_arrayref("select index, count from foo");
    if (@$dat == $SIZE) {
         $count{$_->[0]}=$_->[1] foreach @$dat;
    } else {
      warn "table not correct size, ", scalar @$dat unless @$dat==0;
      $dbh->do("truncate foo");
      %count=();
      my $sth=$dbh->prepare("insert into foo (index, count, text_array) values (?,0,?)");
      $dbh->begin_work();
      ### generate a random array, that contains both the target, and a bunch of other random stuff which 
      ### which doesn't match to any valid target
      $sth->execute($_, [map md5_hex($_), shuffle ($_, map {-int(rand()*1000)-10} 1..100)] ) foreach 1..$SIZE;
      $dbh->commit();
    };
  };
  last unless $@;
  warn "Failed with $@, trying again";
  sleep 1;
};
warn "init done";

## Fork of a given number of child presses, opening pipes for them to 
## communicate back to the parent.  Communication is a one-time shot,
## at the end of their lifetimes.
my @child_pipe;
my $pipe_up;
foreach (1.. ((@ARGV and $ARGV[0]>0) ? $ARGV[0] : 4)) {
    my $pipe = new IO::Pipe;
    defined (my $fork = fork) or die "fork failed: $!";
    if ($fork) {
      push @child_pipe, {pipe => $pipe->reader(), pid => $fork};
    } else {
      $pipe_up=$pipe->writer();
      @child_pipe=();
      last;
    };
};

#warn "fork done";

if (@child_pipe) {
  #warn "in harvest";
  my %in_flight;
  ### harvest children data, which consists of the in-flight item, plus a hash with the counts of all confirmed-committed items
  local $/;
  foreach my $handle ( @child_pipe ) {
    my $data=Storable::fd_retrieve($handle->{pipe});
    $in_flight{$data->[0]}=() if defined $data->[0];
    while (my ($k,$v)=each %{$data->[1]}) {
       $count{$k}+=$v;
    };
    close $handle->{pipe} or die "$$ closing child failed with bang $!, and question $?";
    my $pid =waitpid $handle->{pid}, 0 ;
    die "$$: my child $pid exited with non-zero status $?" if $?;
  };
  #warn "harvest done";
  my ($dat,$dat2);
  foreach (1..300) {
       sleep 1;
       ## used to do just the connect in the eval loop,
       ## but sometimes the database crashed again during the
       ## query, so do it all in the eval-loop
       eval {
         warn "summary attempt $_" if $_>1;
         my $dbh = dbconnect();
         ## detect wrap around shutdown (actually not shutdown, but read-onlyness) and bail out
         ## need to detect before $dat is set, or else it won't trigger a Perl fatal error.
         $dbh->do("create temporary table aldjf (x serial)");
         $dat = $dbh->selectall_arrayref("select index, count from foo");
         warn "sum is ", $dbh->selectrow_array("select sum(count) from foo"), "\n";
         warn "count is ", $dbh->selectrow_array("select count(*) from foo"), "\n";
         # try to force it to walk the index to get to each row, so corrupt indexes are detected
         # (Without the "where index is not null", it won't use an index scan no matter what)
         $dat2 = $dbh->selectall_arrayref("set enable_seqscan=off; select index, count from foo where index is not null");
       };
       last unless $@;
       warn $@;
  };
  die "Database didn't recover even after 5 minutes, giving up" unless $dat2;
  ## don't do sorts in SQL because it might change the execution plan
  @$dat=sort {$a->[0]<=>$b->[0]} @$dat;
  @$dat2=sort {$a->[0]<=>$b->[0]} @$dat2;
  foreach (@$dat) {
    $_->[0] == $dat2->[0][0] and $_->[1] == $dat2->[0][1] or die "seq scan doesn't match index scan"; shift @$dat2;
    no warnings 'uninitialized';
    warn "For $_->[0], $_->[1] != $count{$_->[0]}", exists $in_flight{$_->[0]}? " in flight":""  if $_->[1] != $count{$_->[0]};
    if ($_->[1] != $count{$_->[0]} and not exists $in_flight{$_->[0]} and defined $ARGV[2]) {
       #bring down the system now, before autovac destroys the evidence
       die;
    };
    delete $count{$_->[0]};
  };
  warn "Left over in %count: @{[%count]}" if %count;
  die if %count and defined $ARGV[2];
  warn "normal exit";
  exit;
};


my %h; # how many time has each item been incremented
my $i; # in flight item which is not reported to have been committed

eval {
  ## do the dbconnect in the eval, in case we crash when some children are not yet
  ## up.  The children that fail to connect in the first place still
  ## need to send the empty data to nstore_fd, or else fd_retieve fatals out.
  my $dbh = dbconnect();
  $dbh->do("SET SESSION enable_seqscan=off"); # GIN likes doing seq scans otherwise
  my $sth=$dbh->prepare("update foo set count=count+1 where text_array @> ?");
  my $sth2=$dbh->prepare("update foo set count=count+1,text_array=? where text_array @> ?");
  foreach (1..($ARGV[1]//1e6)) {
    $i=1+int rand($SIZE);
    my $c;
    if (rand()<0.01) {
      ### generate a new random array, that contains both the target, and a bunch of other random stuff
      my $new_array= [map md5_hex($_), shuffle ($i, map {-int(rand()*1000)-10} 1..100)];
      $c = $sth2->execute($new_array, [md5_hex($i)]);
    } else {
      $c = $sth->execute([md5_hex($i)]);
    };
    $c == 1 or die "update did not update 1 row: key $i updated $c";
    $h{$i}++;
    undef $i;
  };
  $@ =~ s/\n/\\n /g if defined $@;
  warn "child exit ", $dbh->state(), " $@" if length $@;
};
$@ =~ s/\n/\\n /g if defined $@;
warn "child abnormal exit $@" if length $@;

Storable::nstore_fd([$i,\%h],$pipe_up);
close $pipe_up or die "$! $?";
