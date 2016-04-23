echo $HOSTNAME

TMPDATA=/tmp/data2
INST=/home/jjanes/pgsql/torn_bisect/

on_exit() {
  echo "Cleaning up"
  $INST/bin/pg_ctl -D $TMPDATA stop -m immediate -w
  ## don't clean up on normal exit, either, as cleaning up by hand is easy 
  ## and it is hard to know that all failure modes go through the other one.
  # rm -r $TMPDATA
  exit 0
}

on_error() {
  echo "Exiting on error"
  $INST/bin/pg_ctl -D $TMPDATA stop -m immediate -w
  # don't clean up, to preserve for forensic analysis.
  # rm -r $TMPDATA/
  exit 1
};

trap 'on_exit' USR2;
trap 'on_exit' INT;

$INST/bin/pg_ctl -D $TMPDATA stop -m immediate -w
rm -r $TMPDATA
$INST/bin/initdb -k -D $TMPDATA || exit

cat <<END  >> $TMPDATA/postgresql.conf
##  Jeff's changes to config for use with recovery stress testing

## can't do these two when testing 9.3
max_replication_slots=3
wal_level = logical

wal_keep_segments=20  ## preserve some evidence

##  Crashes are driven by checkpoints, so we want to do them often
#checkpoint_segments = 1
max_wal_size = 48MB 
min_wal_size = 32MB

checkpoint_timeout = 30s
checkpoint_warning = 0
#archive_mode = on
## There is a known race condition that sometimes causes auto restart to fail when archiving is on.
## that is annoying, so turn it off unless we specifically want to test the on condition.
archive_mode = off
archive_command = 'echo archive_command %p %f `date`'       # Don't actually archive, just make pgsql think we are
archive_timeout = 30
log_checkpoints = on
log_autovacuum_min_duration=0
track_io_timing=on
autovacuum_naptime = 10s
## if updates are not HOT, the table/index can easily bloat faster than default throttled autovac can possibly
## cope. So crank it up.
autovacuum_vacuum_cost_delay = 2ms
log_line_prefix = '%p %i %e %m:'
restart_after_crash = on
## Since we crash the PG software, not the OS, fsync does not matter as the surviving OS is obligated to provide a 
## consistent view of the written-but-not-fsynced data even after PG restarts.  Turning it off gives more 
## testing per unit of time.
fsync=off
log_error_verbosity = verbose
JJ_vac=1
shared_preload_libraries = 'pg_stat_statements' 

wal_compression=1
track_commit_timestamp=1
### Letting work_mem be high can sometimes lead to it using a seq_scan instead of the gin index
### but in 9.5 and above, use gin_pending_list_limit instead.
#work_mem=1MB
gin_pending_list_limit=1MB
END

## the extra verbosity is often just annoying, turn it off when not needed.
## (but leave them turned on above, so I remember what settings I need when
## I do need it.

cat <<END  >> $TMPDATA/postgresql.conf
log_error_verbosity = default
log_checkpoints = off
log_autovacuum_min_duration=-1
JJ_vac=0
END

$INST/bin/pg_ctl -D $TMPDATA start -w || exit
$INST/bin/createdb
$INST/bin/psql -c 'create extension pageinspect'
$INST/bin/psql -c 'create extension pgstattuple'
$INST/bin/psql -c 'create extension pg_stat_statements'
$INST/bin/psql -c "create extension pg_freespacemap"

##  run the initial load now, before JJ_torn_page is turned on,
##  or else we crash before even getting the table initialized due to WAL of the GIN or GIST index build.
perl count.pl 8 0|| on_error; 

### Occasionally useful monitoring queries

#while (true) ; do psql -c "set enable_seqscan=off; explain (analyze,buffers) update foo set count=count+0 where text_array @> ('{'||md5(679::text)||'}')::text[];"; sleep 1; done &
#psql -c "SELECT * FROM gin_metapage_info(get_raw_page('foo_text_array_idx', 0));" -x
#while (true) ; do  psql -c "\dit+ ";  sleep 5; done &

for g in `seq 1 5000` ; do
  $INST/bin/pg_ctl -D $TMPDATA restart -o "--ignore_checksum_failure=0 --JJ_torn_page=1000 --JJ_xid=4" -w
  echo JJ starting loop $g;
  for f in `seq 1 100`; do 
    #$INST/bin/psql -c 'SELECT datname, datfrozenxid, age(datfrozenxid) FROM pg_database;'; 
    ## on_error is needed to preserve database for inspection.  Otherwise autovac will destroy evidence.
    perl count.pl 8 || on_error; 
  done;
  echo JJ ending loop $g;
  ## give autovac a chance to run to completion
  # need to disable crashing, as sometimes the vacuum itself triggers the crash
  $INST/bin/pg_ctl -D $TMPDATA restart -o "--ignore_checksum_failure=0 --JJ_torn_page=0 --JJ_xid=4" -w || (sleep 5; \
  $INST/bin/pg_ctl -D $TMPDATA restart -o "--ignore_checksum_failure=0 --JJ_torn_page=0 --JJ_xid=4" -w || on_error;)
  ## trying to get autovac to work in the face of consistent crashing 
  ## is just too hard, so do manual vacs unless autovac is specifically 
  ## what you are testing.
  #$INST/bin/vacuumdb -a -F || on_error;
  ## or sleep a few times in the hope autovac can get it done, if you want to test that.
  #$INST/bin/psql -c 'select pg_sleep(120)' || (sleep 5; $INST/bin/psql -c 'select pg_sleep(120)') || (sleep 5; $INST/bin/psql -c 'select pg_sleep(120)')## give autovac a chance to do its thing
  echo JJ ending sleep after loop $g;
done;
on_exit
