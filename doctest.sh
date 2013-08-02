#!/usr/bin/env bash
# doctest.sh - Automatic tests for shell script command lines
#              https://github.com/aureliojargas/doctest.sh
# License: MIT
# by Aurelio Jargas (http://aurelio.net), since 2013-07-24
#
# Exit codes:
#   0  All tests passed, or normal operation (--help, --list, ...)
#   1  One or more tests have failed
#   2  An error occurred (file not found, invalid range, ...)

my_name="$(basename "$0")"
my_version='dev'
my_help="\
Usage: $my_name [options] <file ...>

Options:
      --diff-options STRING   Customize options for diff (default: -u)
  -1, --first                 Stop the tests on the first error
      --inline-prefix STRING  Set inline output prefix (default: '#→ ')
  -l, --list                  List all the tests (no execution)
  -L, --list-run              List all the tests with OK/FAIL status
      --no-color              Turn off colors in the program output
  -n, --number RANGE          Run specific tests, by number (1,2,4-7)
      --prefix STRING         Set command line prefix (default: none)
      --prompt STRING         Set prompt string (default: '$ ')
  -q, --quiet                 Quiet operation, no output shown
  -v, --verbose               Show each test being executed
  -V, --version               Show program version and exit"

# Customization (if needed), most may be altered by command line options
prefix=''
prompt='$ '
inline_prefix='#→ '
diff_options='-u'
user_range=''
temp_dir="${TMPDIR:-/tmp}/doctest.$$"
# Note: using temporary files for compatibility, since <(...) is not portable.

# Flags (0=off, 1=on), some may be altered by command line options
debug=0
quiet=0
verbose=0
list_mode=0
list_run=0
use_colors=1
stop_on_first_error=0
separator_line_shown=0

# Do not change these vars
test_number=0
line_number=0
nr_files=0
nr_total_tests=0      # count only executed (not skipped with -n) tests
nr_total_errors=0
nr_file_tests=0       # count only executed (not skipped with -n) tests
nr_file_errors=0
files_stat_message=''
original_dir=$(pwd)
tests_range=
test_command=
test_inline=
test_mode=
test_status=2
test_diff=
test_ok_text=
test_ok_file="$temp_dir/ok.txt"
test_output_file="$temp_dir/output.txt"
temp_file="$temp_dir/temp.txt"

# Special useful chars
tab='	'
nl='
'

# Handle command line options
while test "${1#-}" != "$1"
do
	case "$1" in
		-q|--quiet     ) shift; quiet=1 ;;
		-v|--verbose   ) shift; verbose=1 ;;
		-l|--list      ) shift; list_mode=1;;
		-L|--list-run  ) shift; list_run=1;;
		-1|--first     ) shift; stop_on_first_error=1 ;;
		-n|--number    ) shift; user_range="$1"; shift ;;
		--no-color     ) shift; use_colors=0 ;;
  		--debug        ) shift; debug=1 ;;
		--include      ) shift; . "$1" ''; shift ;;  # XXX dev temp option
		--diff-options ) shift; diff_options="$1"; shift ;;
		--inline-prefix) shift; inline_prefix="$1"; shift ;;
		--prompt       ) shift; prompt="$1"; shift ;;
		--prefix       ) shift; prefix="$1"; shift ;;
		-V|--version   ) printf '%s\n' "$my_name $my_version"; exit 0 ;;
		-h|--help      ) printf '%s\n' "$my_help"; exit 0 ;;
		--) shift; break ;;
		*) break ;;
	esac
done

# Command line options consumed, now it's just the files
nr_files=$#

# No files? Show help.
if test $nr_files -eq 0
then
	printf '%s\n' "$my_help"
	exit 0
fi

# Handy shortcuts for prefixes
case "$prefix" in
	tab)
		prefix="$tab"
	;;
	0)
		prefix=''
	;;
	[1-9] | [1-9][0-9])  # 1-99
		# convert number to spaces: 2 => '  '
		prefix=$(printf "%${prefix}s" ' ')
	;;
	*\\*)
		prefix="$(printf %b "$prefix")"  # expand \t and others
	;;
esac

# Set colors
# Note: colors must be readable in dark and light backgrounds
if test $use_colors -eq 1
then
	color_red=$(  printf '\033[31m')
	color_green=$(printf '\033[32m')
	color_blue=$( printf '\033[34m')
	color_cyan=$( printf '\033[36m')
	color_off=$(  printf '\033[m')
fi

# Find the terminal width
# The COLUMNS env var is set by Bash (must be exported in ~/.bashrc).
# In other shells, try to use tput cols (not POSIX).
# If not, defaults to 50 columns, a conservative amount.
: ${COLUMNS:=$(tput cols 2> /dev/null)}
: ${COLUMNS:=50}

# Utilities, prefixed by _ to avoid overwriting command names
_clean_up ()
{
	rm -rf "$temp_dir"
}
_message ()
{
	test $quiet -eq 1 && return
	printf '%s\n' "$*"
	separator_line_shown=0
}
_error ()
{
	_message "$my_name: Error: $1" >&2
	_clean_up
	exit 2
}
_debug ()
{
	test $debug -eq 1 && _message "${color_blue}$@${color_off}"
}
_separator_line ()
{
	printf "%${COLUMNS}s" ' ' | tr ' ' -
}
_list_line ()  # $1=command $2=ok|fail
{
	# Compose the output lines for --list and --list-run

	local cmd="$1"
	local n=$test_number

	case "$2" in
		ok)
			# Green line or OK stamp (--list-run)
			if test $use_colors -eq 1
			then
				_message "${color_green}${n}${tab}${cmd}${color_off}"
			else
				_message "${n}${tab}OK${tab}${cmd}"
			fi
		;;
		fail)
			# Red line or FAIL stamp (--list-run)
			if test $use_colors -eq 1
			then
				_message "${color_red}${n}${tab}${cmd}${color_off}"
			else
				_message "${n}${tab}FAIL${tab}${cmd}"
			fi
		;;
		*)
			# Normal line, no color, no stamp (--list)
			_message "${n}${tab}${cmd}"
		;;
	esac
}
_parse_range ()
{
	# Parse -n, --number ranges and save results to $tests_range
	#
	#     Supported formats            Parsed
	#     ------------------------------------------------------
	#     Single:  1                    :1:
	#     List:    1,3,4,7              :1:3:4:7:
	#     Range:   1-4                  :1:2:3:4:
	#     Mixed:   1,3,4-7,11,13-15     :1:3:4:5:6:7:11:13:14:15:
	#
	#     Reverse ranges and repeated/unordered numbers are ok.
	#     Later we will just grep for :number: in each test.

	local part
	local n1
	local n2
	local operation
	local numbers=':'  # :1:2:4:7:

	case "$user_range" in
		# No range, nothing to do
		0 | '')
			return 0
		;;
		# Error: strange chars, not 0123456789,-
		*[!0-9,-]*)
			return 1
		;;
	esac

	# OK, all valid chars in range, let's parse them

	# Loop each component: a number or a range
	for part in $(echo $user_range | tr , ' ')
	do
		# If there's an hyphen, it's a range
		case $part in
			*-*)
				# Error: Invalid range format, must be: number-number
				echo $part | grep '^[0-9][0-9]*-[0-9][0-9]*$' > /dev/null || return 1

				n1=${part%-*}
				n2=${part#*-}

				operation='+'
				test $n1 -gt $n2 && operation='-'

				# Expand the range (1-4 => 1:2:3:4)
				part=$n1:
				while test $n1 -ne $n2
				do
					n1=$(($n1 $operation 1))
					part=$part$n1:
				done
				part=${part%:}
			;;
		esac

		# Append the number or expanded range to the holder
		test $part != 0 && numbers=$numbers$part:
	done

	# Save parsed range
	test $numbers != ':' && tests_range=$numbers
	return 0
}
_reset_test_data ()
{
	test_command=
	test_inline=
	test_mode=
	test_status=2
	test_diff=
	test_ok_text=
}
_run_test ()
{
	test_number=$(($test_number + 1))

	# Test range on: skip this test if it's not listed in $tests_range
	if test -n "$tests_range" && test "$tests_range" = "${tests_range#*:$test_number:}"
	then
		_reset_test_data
		return 0
	fi

	nr_total_tests=$(($nr_total_tests + 1))
	nr_file_tests=$(($nr_file_tests + 1))

	# List mode: just show the command and return (no execution)
	if test $list_mode -eq 1
	then
		_list_line "$test_command"
		_reset_test_data
		return 0
	fi

	# Verbose mode: show the command that will be tested
	if test $verbose -eq 1
	then
		_message "${color_cyan}=======[$test_number] $test_command${color_off}"
	fi

	#_debug "[ EVAL  ] $test_command"

	# Execute the test command, saving output (STDOUT and STDERR)
	eval "$test_command" > "$test_output_file" 2>&1

	#_debug "[OUTPUT ] $(cat "$test_output_file")"

	# The command output matches the expected output?
	case $test_mode in
		text)
			# Inline OK text represents a full line, with \n
			printf '%s\n' "$test_inline" > "$test_ok_file"

			test_diff=$(diff $diff_options "$test_ok_file" "$test_output_file")
			test_status=$?
		;;
		regex)
			egrep "$test_inline" "$test_output_file" > /dev/null
			test_status=$?

			# Failed, now we need a real file to make the diff
			if test $test_status -eq 1
			then
				printf %s "$test_inline" > "$test_ok_file"
				test_diff=$(diff $diff_options "$test_ok_file" "$test_output_file")

			# Regex errors are common and user must take action to fix them
			elif test $test_status -eq 2
			then
				_error "egrep: check your inline regex at line $line_number of $test_file"
			fi
		;;
		file)
			# Abort when ok file not found/readable
			if test ! -f "$test_inline" || test ! -r "$test_inline"
			then
				_error "cannot read inline output file '$test_inline', from line $line_number of $test_file"
			fi

			test_diff=$(diff $diff_options "$test_inline" "$test_output_file")
			test_status=$?
		;;
		output)
			printf %s "$test_ok_text" > "$test_ok_file"
			test_diff=$(diff $diff_options "$test_ok_file" "$test_output_file")
			test_status=$?
		;;
		*)
			_error "unknown test mode '$test_mode'"
		;;
	esac

	# Test failed :(
	if test $test_status -ne 0
	then
		nr_file_errors=$(($nr_file_errors + 1))
		nr_total_errors=$(($nr_total_errors + 1))

		# Decide the message format
		if test $list_run -eq 1
		then
			# List mode
			_list_line "$test_command" fail
		else
			# Normal mode: show FAILED message and the diff
			if test $separator_line_shown -eq 0  # avoid dups
			then
				_message "${color_red}$(_separator_line)${color_off}"
			fi
			_message "${color_red}[FAILED #$test_number] $test_command${color_off}"
			test $quiet -eq 1 || printf '%s\n' "$test_diff" | sed '1,2 d'  # no +++/--- headers
			_message "${color_red}$(_separator_line)${color_off}"
			separator_line_shown=1
		fi

		# Should I abort now?
		if test $stop_on_first_error -eq 1
		then
			_clean_up
			exit 1
		fi

	# Test OK
	else
		test $list_run -eq 1 && _list_line "$test_command" ok
	fi

	_reset_test_data
}
_process_test_file ()
{
	# Reset counters
	nr_file_tests=0
	nr_file_errors=0
	line_number=0

	# Loop for each line of input file
	# Note: changing IFS to avoid right-trimming of spaces/tabs
	# Note: read -r to preserve the backslashes (also works in dash shell)
	while IFS='' read -r input_line || test -n "$input_line"
	do
		line_number=$(($line_number + 1))
		case "$input_line" in

			# Prompt alone: closes previous command line (if any)
			"$prefix$prompt" | "$prefix${prompt% }" | "$prefix$prompt ")
				#_debug "[ CLOSE ] $input_line"

				# Run pending tests
				test -n "$test_command" && _run_test
			;;

			# This line is a command line to be tested
			"$prefix$prompt"*)
				#_debug "[CMDLINE] $input_line"

				# Run pending tests
				test -n "$test_command" && _run_test

				# Remove the prompt
				test_command="${input_line#$prefix$prompt}"

				# This is a special test with inline output?
				if printf '%s\n' "$test_command" | grep "$inline_prefix" > /dev/null
				then
					# Separate command from inline output
					test_command="${test_command%$inline_prefix*}"
					test_inline="${input_line##*$inline_prefix}"

					#_debug "[NEW CMD] $test_command"
					#_debug "[OK TEXT] $test_inline$"

					# Maybe the OK text has options?
					case "$test_inline" in
						'--regex '*)
							test_inline=${test_inline#--regex }
							test_mode='regex'
						;;
						'--file '*)
							test_inline=${test_inline#--file }
							test_mode='file'
						;;
						'--text '*)
							test_inline=${test_inline#--text }
							test_mode='text'
						;;
						*)
							test_mode='text'
						;;
					esac

					# An empty inline parameter is an error user must see
					if test -z "$test_inline" && test "$test_mode" != 'text'
					then
						_error "missing inline output $test_mode at line $line_number of $test_file"
					fi

					# Since we already have the command and the output, run test
					_run_test
				else
					# It's a normal command line, output begins in next line
					test_mode='output'

					#_debug "[NEW CMD] $test_command"
				fi
			;;

			# Test output, blank line or comment
			*)
				#_debug "[ ? LINE] $input_line"

				# Ignore this line if there's no pending test
				test -n "$test_command" || continue

				# Required prefix is missing: we just left a command block
				if test -n "$prefix" && test "${input_line#$prefix}" = "$input_line"
				then
					#_debug "[BLOKOUT] $input_line"

					# Run the pending test and we're done in this line
					_run_test
					continue
				fi

				# This line is a test output, save it (without prefix)
				test_ok_text="$test_ok_text${input_line#$prefix}$nl"

				#_debug "[OK LINE] $input_line"
			;;
		esac
	done < "$temp_file"

	#_debug "[LOOPOUT] test_command: $test_command"

	# Run pending tests
	test -n "$test_command" && _run_test
}


# Parse and validate --number option value, if informed
_parse_range
if test $? -eq 1
then
	_error "invalid argument for -n or --number: $user_range"
fi

### Real execution begins here

# Create temp dir, protected from others
umask 077 && mkdir "$temp_dir" || _error "cannot create temporary dir: $temp_dir"

# Loop for each input file
while test $# -gt 0
do
	test_file="$1"
	shift

	# Some tests may "cd" to another dir, we need to get back
	# to preserve the relative paths of the input files
	cd "$original_dir"

	# Abort when test file not found/readable
	if test ! -f "$test_file" || test ! -r "$test_file"
	then
		_error "cannot read input file: $test_file"
	fi

	# In multifile mode, identify the current file
	if test $nr_files -gt 1
	then
		if test $list_mode -ne 1 && test $list_run -ne 1
		then
			# Normal mode, show a message
			_message "Testing file $test_file"
		else
			# List mode, show ------ and the filename
			_message $(_separator_line | cut -c 1-40) $test_file
		fi
	fi

	# Convert Windows files (CRLF) to the Unix format (LF)
	# Note: the temporary file is required, because doing "sed | while" opens
	#       a subshell and global vars won't be updated outside the loop.
	sed "s/$(printf '\r')$//" "$test_file" > "$temp_file"

	# The magic happens here
	_process_test_file

	# Abort when no test found
	if test $nr_file_tests -eq 0 && test -z "$tests_range"
	then
		_error "no test found in input file: $test_file"
	fi

	# Compose file stats message
	nr_file_ok=$(($nr_file_tests - $nr_file_errors))
	if test $nr_file_errors -eq 0
	then
		msg=$(printf '%3d ok            %s' $nr_file_ok "$test_file")
	else
		msg=$(printf '%3d ok, %3d fail  %s' $nr_file_ok $nr_file_errors "$test_file")
	fi

	# Append file stats to global holder
	files_stat_message=$(printf '%s\n%s' "$files_stat_message" "$msg")
done

_clean_up

# List mode has no stats
if test $list_mode -eq 1 || test $list_run -eq 1
then
	if test $nr_total_errors -eq 0
	then
		exit 0
	else
		exit 1
	fi
fi

# Range active, but no test matched :(
if test $nr_total_tests -eq 0 && test -n "$tests_range"
then
	_error "no test found for the specified number or range '$user_range'"
fi

# Show stats
if test $nr_files -gt 1
then
	_message
	_message $(_separator_line | tr - =)
	_message "${files_stat_message#?}"  # remove \n at start
	_message $(_separator_line | tr - =)
	_message
fi

# The final message: WIN or FAIL?
if test $nr_total_errors -eq 0
then
	if test $nr_total_tests -eq 1
	then
		_message "${color_green}OK!${color_off} The single test has passed."
	elif test $nr_total_tests -lt 50
	then
		_message "${color_green}OK!${color_off} All $nr_total_tests tests have passed."
	elif test $nr_total_tests -lt 100
	then
		_message "${color_green}YOU WIN!${color_off} All $nr_total_tests tests have passed."
	else
		_message "${color_green}YOU WIN! PERFECT!${color_off} All $nr_total_tests tests have passed."
	fi
	exit 0
else
	test $nr_files -eq 1 && _message  # separate from previous error message

	if test $nr_total_tests -eq 1
	then
		_message "${color_red}FAIL:${color_off} The single test has failed."
	elif test $nr_total_errors -eq $nr_total_tests && test $nr_total_errors -lt 50
	then
		_message "${color_red}COMPLETE FAIL!${color_off} All $nr_total_tests tests have failed."
	elif test $nr_total_errors -eq $nr_total_tests
	then
		_message "${color_red}EPIC FAIL!${color_off} All $nr_total_tests tests have failed."
	else
		_message "${color_red}FAIL:${color_off} $nr_total_errors of $nr_total_tests tests have failed."
	fi
	exit 1
fi
# Note: Those messages are for FUN. When automating, check the exit code.

