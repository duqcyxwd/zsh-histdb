which sqlite3 >/dev/null 2>&1 || return;

zmodload zsh/datetime # for EPOCHSECONDS
zmodload zsh/system # for sysopen
builtin which sysopen &>/dev/null || return; # guard against zsh older than 5.0.8.

zmodload -F zsh/stat b:zstat # just zstat
autoload -U add-zsh-hook

typeset -g HISTDB_QUERY=""
if [[ -z ${HISTDB_FILE} ]]; then
    typeset -g HISTDB_FILE="${HOME}/.histdb/zsh-history.db"
else
    typeset -g HISTDB_FILE
fi

typeset -g HISTDB_FD
typeset -g HISTDB_INODE=()
typeset -g HISTDB_SESSION=""
typeset -g HISTDB_HOST=""
typeset -g HISTDB_INSTALLED_IN="${(%):-%N}"



sql_escape () {
    print -r -- ${${@//\'/\'\'}//'\x00'}
}

_histdb_query () {
    sqlite3 -batch -noheader -cmd ".timeout 1000" "${HISTDB_FILE}" "$@"
    [[ "$?" -ne 0 ]] && echo "error in $@"
}

_histdb_stop_sqlite_pipe () {
    if [[ -n $HISTDB_FD ]]; then
        if print -nu$HISTDB_FD; then
            exec {HISTDB_FD}>&-;  # https://stackoverflow.com/a/22794374/2639190
        fi
    fi
    # Sometimes, it seems like closing the fd does not terminate the
    # sqlite batch process, so here is a horrible fallback.
    # if [[ -n $HISTDB_SQLITE_PID ]]; then
    #     ps -o args= -p $HISTDB_SQLITE_PID | read -r args
    #     if [[ $args == "sqlite3 -batch ${HISTDB_FILE}" ]]; then
    #         kill -TERM $HISTDB_SQLITE_PID
    #     fi
    # fi
}


_histdb_start_sqlite_pipe () {
    local PIPE==(<<<'')
    setopt local_options no_notify no_monitor
    mkfifo $PIPE
    sqlite3 -batch -noheader "${HISTDB_FILE}" < $PIPE >/dev/null &|
    sysopen -w -o cloexec -u HISTDB_FD -- $PIPE
    command rm $PIPE
    zstat -A HISTDB_INODE +inode ${HISTDB_FILE}
}

_histdb_query_batch () {
    local CUR_INODE
    zstat -A CUR_INODE +inode ${HISTDB_FILE}
    if [[ $CUR_INODE != $HISTDB_INODE ]]; then
        _histdb_stop_sqlite_pipe
        _histdb_start_sqlite_pipe
    fi
    cat >&$HISTDB_FD
    echo ';' >&$HISTDB_FD # make sure last command is executed
}

_histdb_init () {
    if [[ -n "${HISTDB_SESSION}" ]]; then
        return
    fi

    if ! [[ -e "${HISTDB_FILE}" ]]; then
        local hist_dir="${HISTDB_FILE:h}"
        if ! [[ -d "$hist_dir" ]]; then
            mkdir -p -- "$hist_dir"
        fi
        _histdb_query <<-EOF
create table commands (id integer primary key autoincrement, argv text, unique(argv) on conflict ignore);
create table places   (id integer primary key autoincrement, host text, dir text, unique(host, dir) on conflict ignore);
create table history  (id integer primary key autoincrement,
                       session int,
                       command_id int references commands (id),
                       place_id int references places (id),
                       exit_status int,
                       start_time int,
                       duration int);
PRAGMA user_version = 2;
EOF
    fi
    if [[ -z "${HISTDB_SESSION}" ]]; then
        ${HISTDB_INSTALLED_IN:h}/histdb-migrate "${HISTDB_FILE}"
        HISTDB_HOST=${HISTDB_HOST:-"'$(sql_escape ${HOST})'"}
        HISTDB_SESSION=$(_histdb_query "select 1+max(session) from history inner join places on places.id=history.place_id where places.host = ${HISTDB_HOST}")
        HISTDB_SESSION="${HISTDB_SESSION:-0}"
        readonly HISTDB_SESSION
    fi

    _histdb_start_sqlite_pipe
    _histdb_query_batch >/dev/null <<EOF
create index if not exists hist_time on history(start_time);
create index if not exists place_dir on places(dir);
create index if not exists place_host on places(host);
create index if not exists history_command_place on history(command_id, place_id);
PRAGMA journal_mode = WAL;
PRAGMA synchronous=normal;
EOF
}

declare -ga _BORING_COMMANDS
_BORING_COMMANDS=("^ls$" "^cd$" "^ " "^histdb" "^top$" "^htop$")

if [[ -z "${HISTDB_TABULATE_CMD[*]:-}" ]]; then
    declare -ga HISTDB_TABULATE_CMD
    HISTDB_TABULATE_CMD=(column -t -s $'\x1f')
fi

_histdb_update_outcome () {
    local retval=$?
    local finished=$EPOCHSECONDS
    [[ -z "${HISTDB_SESSION}" ]] && return

    _histdb_init
    _histdb_query_batch <<EOF &|
update history set
      exit_status = ${retval},
      duration = ${finished} - start_time
where id = (select max(id) from history) and
      session = ${HISTDB_SESSION} and
      exit_status is NULL;
EOF
}

_histdb_addhistory () {
    local cmd="${1[0, -2]}"

    if [[ -o histignorespace && "$cmd" =~ "^ " ]]; then
        return 0
    fi
    if [[ ${cmd} == ${~HISTORY_IGNORE} ]]; then
        return 0
    fi
    local boring
    for boring in "${_BORING_COMMANDS[@]}"; do
        if [[ "$cmd" =~ $boring ]]; then
            return 0
        fi
    done

    local cmd="'$(sql_escape $cmd)'"
    local pwd="'$(sql_escape ${PWD})'"
    local started=$EPOCHSECONDS
    _histdb_init

    if [[ "$cmd" != "''" ]]; then
        _histdb_query_batch <<EOF &|
insert into commands (argv) values (${cmd});
insert into places   (host, dir) values (${HISTDB_HOST}, ${pwd});
insert into history
  (session, command_id, place_id, start_time)
select
  ${HISTDB_SESSION},
  commands.id,
  places.id,
  ${started}
from
  commands, places
where
  commands.argv = ${cmd} and
  places.host = ${HISTDB_HOST} and
  places.dir = ${pwd}
;
EOF
    fi
    return 0
}


histdb-top () {
    _histdb_init
    local sep=$'\x1f'
    local field
    local join
    local table
    1=${1:-cmd}
    case "$1" in
        dir)
            field=places.dir
            join='places.id = history.place_id'
            table=places
            ;;
        cmd)
            field=commands.argv
            join='commands.id = history.command_id'
            table=commands
            ;;;
    esac
    _histdb_query -separator "$sep" \
            -header \
            "select count(*) as count, places.host, replace($field, '
', '
$sep$sep') as ${1:-cmd} from history left join commands on history.command_id=commands.id left join places on history.place_id=places.id group by places.host, $field order by count(*)" | \
        "${HISTDB_TABULATE_CMD[@]}"
}

histdb-sync () {
    _histdb_init

    # this ought to apply to other readers?
    echo "truncating WAL"
    echo 'pragma wal_checkpoint(truncate);' | _histdb_query_batch

    local hist_dir="${HISTDB_FILE:h}"
    if [[ -d "$hist_dir" ]]; then
        () {
            setopt local_options no_pushd_ignore_dups

            pushd -q "$hist_dir"
            if [[ $(git rev-parse --is-inside-work-tree) != "true" ]] || [[ "$(git rev-parse --show-toplevel)" != "${PWD:A}" ]]; then

                echo "Initializing git repository"
                git init

                echo "git config merge.histdb.driver ${HISTDB_INSTALLED_IN:h}/histdb-merge %O %A %B"
                git config merge.histdb.driver "${HISTDB_INSTALLED_IN:h}/histdb-merge %O %A %B"

                echo "${HISTDB_FILE:t} merge=histdb" >>! .gitattributes

                git add .gitattributes
                git add "${HISTDB_FILE:t}"

            fi

            echo "Close sqlite pipe _histdb_stop_sqlite_pipe"
            _histdb_stop_sqlite_pipe # Stop in case of a merge, starting again afterwards

            echo "git commit -am history && git pull --no-edit && git push"
            git commit -am "history" && git pull --no-edit && git push

            echo "Start sqlite pipe"
            _histdb_start_sqlite_pipe
            popd -q
        }
    fi

    echo 'pragma wal_checkpoint(passive);' | _histdb_query_batch
}

histdb-git-compact () {
  # Accept commit hash as parameter or use default
  # This function creates a new Git history starting from the specified commit
  # It preserves all changes but discards the history before that point
  local commit_hash="${1}"

  # Validate the commit hash exists
  if ! git rev-parse --verify "$commit_hash" &>/dev/null; then
    echo "Error: Commit hash '$commit_hash' does not exist in the repository."
    echo "Usage: histdb_git_clean [commit_hash]"
    return 1
  fi

  echo "Using commit hash: $commit_hash"

  git config merge.histdb.driver "${HISTDB_INSTALLED_IN:h}/histdb-merge %O %A %B"

  # New steps
  git checkout --orphan new-master "$commit_hash"
  git commit -m "Start new history"

  # Cherry-pick commits from the specified commit to master
  git cherry-pick --allow-empty --keep-redundant-commits -m 1 "$commit_hash"..master

}

histdb-git-clean() {
  # This function finalizes the Git history cleanup process
  # It removes the old master branch, renames the current branch to master,
  # cleans up references, and force pushes the new history

  git branch -D master
  git branch -m master

  # Force clean old Git history references
  git reflog expire --expire=now --all
  git gc --prune=now --aggressive

  git push -f origin master

}


histdb-summary() {
    _histdb_init

    local total_count=$(_histdb_query "SELECT COUNT(*) FROM history")
    local today_count=$(_histdb_query "SELECT COUNT(*) FROM history WHERE datetime(start_time, 'unixepoch') >= datetime('now', 'start of day')")
    local yesterday_count=$(_histdb_query "SELECT COUNT(*) FROM history WHERE datetime(start_time, 'unixepoch') >= datetime('now', 'start of day', '-1 day') AND datetime(start_time, 'unixepoch') < datetime('now', 'start of day')")
    local week_count=$(_histdb_query "SELECT COUNT(*) FROM history WHERE datetime(start_time, 'unixepoch') >= datetime('now', '-7 days')")
    local unique_cmds=$(_histdb_query "SELECT COUNT(DISTINCT command_id) FROM history")
    local unique_dirs=$(_histdb_query "SELECT COUNT(DISTINCT place_id) FROM history")
    local error_count=$(_histdb_query "SELECT COUNT(*) FROM history WHERE exit_status != 0")
    local most_used=$(_histdb_query "SELECT commands.argv, COUNT(*) as count FROM history JOIN commands ON history.command_id = commands.id GROUP BY commands.argv ORDER BY count DESC LIMIT 1")
    local most_used_cmd=$(echo "$most_used" | cut -d'|' -f1)
    local most_used_count=$(echo "$most_used" | cut -d'|' -f2)
    local avg_duration=$(_histdb_query "SELECT ROUND(AVG(duration), 2) FROM history WHERE duration IS NOT NULL")

    echo "┌─────────────────────────────────────────────┐"
    echo "│             HISTORY DB SUMMARY              │"
    echo "├─────────────────────────────────────────────┤"
    echo "│ Total commands:       $total_count"
    echo "│ Commands today:       $today_count"
    echo "│ Commands yesterday:   $yesterday_count"
    echo "│ Commands this week:   $week_count"
    echo "│ Unique commands:      $unique_cmds"
    echo "│ Unique directories:   $unique_dirs"
    echo "│ Commands with errors: $error_count"
    echo "│ Most used command:    $most_used_cmd ($most_used_count times)"
    echo "│ Average duration:     ${avg_duration}s"
    echo "└─────────────────────────────────────────────┘"
}

histdb () {
    _histdb_init
    local -a opts
    local -a hosts
    local -a indirs
    local -a atdirs
    local -a sessions

    zparseopts -E -D -a opts \
               -host+::=hosts \
               -in+::=indirs \
               -at+::=atdirs \
               -forget \
               -yes \
               -detail \
               -sep:- \
               -exact \
               d h -help \
               s+::=sessions \
               -from:- -until:- -limit:- \
               -status:- -desc

    local usage="usage:$0 terms [--desc] [--host[ x]] [--in[ x]] [--at] [-s n]+* [-d] [--detail] [--forget] [--yes] [--exact] [--sep x] [--from x] [--until x] [--limit n] [--status x]
    --desc     reverse sort order of results
    --host     print the host column and show all hosts (otherwise current host)
    --host x   find entries from host x
    --in       find only entries run in the current dir or below
    --in x     find only entries in directory x or below
    --at       like --in, but excluding subdirectories
    -s n       only show session n
    -d         debug output query that will be run
    --detail   show details
    --forget   forget everything which matches in the history
    --yes      don't ask for confirmation when forgetting
    --exact    don't match substrings
    --sep x    print with separator x, and don't tabulate
    --from x   only show commands after date x (sqlite date parser)
    --until x  only show commands before date x (sqlite date parser)
    --limit n  only show n rows. defaults to $LINES or 25
    --status x only show rows with exit status x. Can be 'error' to find all nonzero."

    local selcols="session as ses, dir"
    local cols="session, replace(places.dir, '$HOME', '~') as dir"
    local where="1"
    if [[ -p /dev/stdout ]]; then
        local limit=""
    else
        local limit="${$((LINES - 4)):-25}"
    fi

    local forget="0"
    local forget_accept=0
    local exact=0

    if (( ${#hosts} )); then
        local hostwhere=""
        local host=""
        for host ($hosts); do
            host="${${host#--host}#=}"
            hostwhere="${hostwhere}${host:+${hostwhere:+ or }places.host='$(sql_escape ${host})'}"
        done
        where="${where}${hostwhere:+ and (${hostwhere})}"
        cols="${cols}, places.host as host"
        selcols="${selcols}, host"
    else
        where="${where} and places.host=${HISTDB_HOST}"
    fi

    if (( ${#indirs} + ${#atdirs} )); then
        local dirwhere=""
        local dir=""
        for dir ($indirs); do
            dir="${${${dir#--in}#=}:-$PWD}"
            dirwhere="${dirwhere}${dirwhere:+ or }places.dir like '$(sql_escape $dir)%'"
        done
        for dir ($atdirs); do
            dir="${${${dir#--at}#=}:-$PWD}"
            dirwhere="${dirwhere}${dirwhere:+ or }places.dir = '$(sql_escape $dir)'"
        done
        where="${where}${dirwhere:+ and (${dirwhere})}"
    fi

    if (( ${#sessions} )); then
        local sin=""
        local ses=""
        for ses ($sessions); do
            ses="${${${ses#-s}#=}:-${HISTDB_SESSION}}"
            sin="${sin}${sin:+, }$ses"
        done
        where="${where}${sin:+ and session in ($sin)}"
    fi

    local sep=$'\x1f'
    local orderdir='asc'
    local debug=0
    local opt=""
    for opt ($opts); do
        case $opt in
            --desc)
                orderdir='desc'
                ;;
            --sep*)
                sep=${opt#--sep}
                ;;
            --from*)
                local from=${opt#--from}
                case $from in
                    -*)
                        from="datetime('now', '$from')"
                        ;;
                    today)
                        from="datetime('now', 'start of day')"
                        ;;
                    yesterday)
                        from="datetime('now', 'start of day', '-1 day')"
                        ;;
                esac
                where="${where} and datetime(start_time, 'unixepoch') >= $from"
                ;;
            --status*)
                local xstatus=${opt#--status}
                case $xstatus in
                    <->)
                        where="${where} and exit_status = $xstatus"
                        ;;
                        error)
                        where="${where} and exit_status <> 0"
                        ;;
                esac
                ;;
            --until*)
                local until=${opt#--until}
                case $until in
                    -*)
                        until="datetime('now', '$until')"
                        ;;
                    today)
                        until="datetime('now', 'start of day')"
                        ;;
                    yesterday)
                        until="datetime('now', 'start of day', '-1 day')"
                        ;;
                esac
                where="${where} and datetime(start_time, 'unixepoch') <= $until"
                ;;
            -d)
                debug=1
                ;;
            --detail)
                cols="${cols}, exit_status, duration "
                selcols="${selcols}, exit_status as [?],duration as secs "
                ;;
            -h|--help)
                echo "$usage"
                return 0
                ;;
            --forget)
                forget=1
                ;;
            --yes)
                forget_accept=1
                ;;
            --exact)
                exact=1
                ;;
            --limit*)
                limit=${opt#--limit}
                ;;
        esac
    done

    if [[ -n "$*" ]]; then
        if [[ $exact -eq 0 ]]; then
            where="${where} and commands.argv glob '*$(sql_escape $@)*'"
        else
            where="${where} and commands.argv = '$(sql_escape $@)'"
        fi
    fi

    if [[ $forget -gt 0 ]]; then
        limit=""
    fi

    # Fix: Handle separator properly
    local seps=""
    if [[ -n "$sep" ]]; then
        seps=$(echo "$cols" | tr -c -d ',' | tr ',' "$sep")
    fi

    cols="${cols}, replace(commands.argv, '
', '
$seps') as argv, max(start_time) as max_start"

    local mst="datetime(max_start, 'unixepoch')"
    local dst="datetime('now', 'start of day')"
    local timecol="strftime(case when $mst > $dst then '%H:%M' else '%d/%m' end, max_start, 'unixepoch', 'localtime') as time"

    selcols="${timecol}, ${selcols}, argv as cmd"

    local r_order="asc"
    if [[ $orderdir == "asc" ]]; then
        r_order="desc"
    fi

    local query="select ${selcols} from (select ${cols}
from
  commands
  join history on history.command_id = commands.id
  join places on history.place_id = places.id
where ${where}
group by history.command_id, history.place_id
order by max_start ${r_order}
${limit:+limit $limit}) order by max_start ${orderdir}"

    ## min max date?
    local count_query="select count(*) from (select ${cols}
from
  commands
  join history on history.command_id = commands.id
  join places  on history.place_id = places.id
where ${where}
group by history.command_id, history.place_id
order by max_start desc) order by max_start ${orderdir}"

    if [[ $debug = 1 ]]; then
        echo "$query"
    else
        local count=$(_histdb_query "$count_query")
        if [[ -p /dev/stdout ]]; then
            buffer() {
                ## this runs out of memory for big files I think perl -e 'local $/; my $stdin = <STDIN>; print $stdin;'
                temp=$(mktemp)
                cat >! "$temp"
                cat -- "$temp"
                rm -f -- "$temp"
            }
        else
            buffer() {
                cat
            }
        fi

        # Fix: Properly handle separator for query
        if [[ "$sep" == $'\x1f' ]]; then
            _histdb_query -header -separator "$sep" "$query" | iconv -f utf-8 -t utf-8 -c | buffer | "${HISTDB_TABULATE_CMD[@]}"
        else
            _histdb_query -header -separator "${sep:-' '}" "$query" | buffer
        fi

        [[ -n $limit ]] && [[ $limit -lt $count ]] && echo "(showing $limit of $count results)"
    fi

    if [[ $forget -gt 0 ]]; then
        if [[ $forget_accept -gt 0 ]]; then
          REPLY=y
        else
          read -q "REPLY?Forget all these results? [y/n] "
        fi
        if [[ $REPLY =~ "[yY]" ]]; then
            _histdb_query "delete from history where
history.id in (
select history.id from
history
  left join commands on history.command_id = commands.id
  left join places on history.place_id = places.id
where ${where})"
            _histdb_query "delete from commands where commands.id not in (select distinct history.command_id from history)"
        fi
    fi
}

# Default HISTDB_HOOK to 1 if not set in environment
: ${HISTDB_HOOK:=1}

if [[ "$HISTDB_HOOK" -eq 1 ]]; then
  add-zsh-hook zshexit _histdb_stop_sqlite_pipe
  add-zsh-hook zshaddhistory _histdb_addhistory
  add-zsh-hook precmd _histdb_update_outcome
fi
