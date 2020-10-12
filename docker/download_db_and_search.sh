#!/bin/bash
##############################################################################
# Script to download a BLAST database and queries in a FASTA file, run a BLAST
# search and copy BLAST results to cloud storage.
##############################################################################

# BLAST parameters
BLAST_PARAMS=

while ! [ "X$1" = X ] ; do
    case $1 in
        --db) DB=$2; shift;;
        --source) DB_SOURCE=$2; shift;;
        --query) QUERY_BATCH=$2; shift;;
        --num-threads) ELB_NUM_CPUS=$2; shift;;
        --program) PROGRAM=$2; shift;;
        --bucket) BUCKET=$2; shift;;
        --params) BLAST_PARAMS=$2; shift;;
        --db-mol-type) DB_MOL_TYPE=$2; shift;;
        *) echo "ERROR: unrecognized argument $1" >&2; exit 1;;
    esac
    shift
done

# Ensure that required variables  are set
if [ -z "${DB}" ] ; then
    echo "ERROR: DB is not set" >&2
    exit 1
else
    echo "DB: ${DB}"
fi

if [ -z "${DB_SOURCE}" ] ; then
    echo "ERROR: DB_SOURCE is not set" >&2
    exit 1
else
    echo "DB_SOURCE: ${DB_SOURCE}"
fi

if [ -z "${QUERY_BATCH}" ] ; then
    echo "ERROR: QUERY_BATCH is not set" >&2
    exit 1
else
    echo "QUERY_BATCH: ${QUERY_BATCH}"
fi

if [ -z "${ELB_NUM_CPUS}" ] ; then
    echo "ERROR: ELB_NUM_CPUS is not set" >&2
    exit 1
else
    echo "ELB_NUM_CPUS: ${ELB_NUM_CPUS}"
fi

if [ -z "${PROGRAM}" ] ; then
    echo "ERROR: PROGRAM is not set" >&2
    exit 1
else
    echo "PROGRAM: ${PROGRAM}"
fi

if [ -z "${BUCKET}" ] ; then
    echo "ERROR: BUCKET is not set" >&2
    exit 1
else
    echo "BUCKET: ${BUCKET}"
fi

if [ -z "${DB_MOL_TYPE}" ] ; then
   echo "ERROR: DB_MOL_TYPE is not set" >&2
   exit 1
else
   echo "DB_MOL_TYPE: ${DB_MOL_TYPE}"
fi

echo "BLAST_PARAMS: ${BLAST_PARAMS}"

# Download BLAST database
# the code has no process synchronization for database download,
# it is assumed that this script is run once at a time per cloud instance
if [ ! -f ${DB}_done ] ; then
   time update_blastdb.pl $DB --source ${DB_SOURCE} --verbose --verbose --verbose --verbose --verbose --verbose
   exit_code=$?
   if [[ ${exit_code} -ne 0 ]] ; then
      echo "update_blastdb.pl exited with status ${exit_code}" >&2
      exit ${exit_code}
   fi

   # test the downloaded database
   blastdbcmd -info -db $DB -dbtype ${DB_MOL_TYPE}
   exit_code=$?
   if [[ ${exit_code} -ne 0 ]] ; then
      echo "blastdbcmd exited with status ${exit_code}" >&2
#      exit ${exit_code}

      echo "update_blastdb.pl failed. Alternative DB download"
      DIR=$(curl -s http://s3.amazonaws.com/ncbi-blast-databases/latest-dir)
      echo "from $DIR"
      for i in $(curl -sf http://s3.amazonaws.com/ncbi-blast-databases/2020-10-10-01-05-01/blastdb-manifest.json | grep ncbi\-blast\-databases | grep /$DB | sed -e 's/[",]//g' | sed -e 's/s3:\//http:\/\/s3.amazonaws.com/g') ; do
         echo "downloading $i"
         curl -sSR -O $i
         exit_code=$?
         if [[ ${exit_code} -ne 0 ]] ; then
             echo "Failed to download $i"
             exit 1
         fi
         echo "done"
      done
      
   fi

   blastdbcheck -db $DB -dbtype ${DB_MOL_TYPE} -no_isam -ends 5
   if [[ ${exit_code} -ne 0 ]] ; then
      echo "blastdbcheck exited with status ${exit_code}" >&2
      exit ${exit_code}
   fi
fi
# FIXME: add blastdb check here
echo done >${DB}_done

# Download queries from S3
aws s3 cp ${QUERY_BATCH} .

# Check if database is memory-mapped (testing purposes)
DBFILES=$(blastdb_path -dbtype nucl -db $DB -getvolumespath)
vmtouch -tvm 5G $DBFILES

# Do the BLAST search 
Q=$(basename ${QUERY_BATCH})
F=${Q%.*}
cmd="time -p ${PROGRAM} -query $Q -db $DB -num_threads ${ELB_NUM_CPUS} -out $F.out ${BLAST_PARAMS}"
echo $cmd 
$cmd 2>$F.err
exit_code=$?
if [[ ${exit_code} -ne 0 ]] ; then
    echo "BLAST search failed with exit status ${exit_code}" >$F.err
    cat $F.err
    exit ${exit_code}
fi
cat $F.err

# Print first few lines of the results (testing purposes)
head $F.out

# Copy results to S3
aws s3 cp $F.out ${BUCKET}/
aws s3 cp $F.err ${BUCKET}/
