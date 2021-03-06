use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Cwd;

use File::Temp qw(tempdir);

my $submitfilter;
BEGIN {
    # poor mans main mocking
    sub find_submitfilter {$submitfilter};

    unshift(@INC, '.', 't');
}

my $mocktime = Test::MockModule->new('DateTime');
$mocktime->mock('now', sub {
                DateTime->new(year => 2018, month => 11, day=>21, hour=>12, minute => 23, second => 37);
                });

require 'qsub.pl';

my $sbatch = which("sbatch");
my $salloc = which("salloc");


# TODO: mixed order (ie permute or no order); error on unknown options

# key = generated command text (w/o sbatch)
# value = arrayref

# default args
my @sa = qw(script arg1);
my @da = (@sa, qw(-l nodes=2:ppn=4));
my @gda = (@da);
$gda[-1] .= ":gpus=2";
my @gda3 = (@da);
$gda3[-1] .= ":gpus=3";
my @mda = (@da);
$mda[-1] .= ":mps=400";
my @ga = (@sa, qw(--gpus=3));

# default batch argument string
my $dba = "--nodes=2 --ntasks=8 --ntasks-per-node=4";
# defaults
my $defs = {
    e => getcwd . '/%x.e%A',
    o => getcwd . '/%x.o%A',
    J => 'script',
    export => 'NONE',
    'get-user-env' => '60L',
    chdir => $ENV{HOME},
};
# default script args
my $dsa = "script arg1";

my %comms = (
    "$dba $dsa", [@da],
    # should be equal
    "$dba --time=1 --mem=1024M $dsa Y", [qw(-l mem=1g,walltime=1), @da, 'Y'],
    "$dba --time=2 --mem=1024M $dsa X", [qw(-l mem=1g -l walltime=1:1), @da, 'X'],
    "$dba --time=3 --mem=1024M $dsa X", [@da, 'X', qw(-l vmem=1g -l walltime=2:2)],

    "$dba --mem=2048M $dsa", [qw(-l vmem=2gb), @da],
    "$dba --mem-per-cpu=10M $dsa", [qw(-l pvmem=10mb), @da],
    "$dba --mem-per-cpu=20M $dsa", [qw(-l pmem=20mb), @da],
    "$dba --abc=123 --def=456 $dsa", [qw(--pass=abc=123 --pass=def=456), @da],
    "$dba --begin=2018-11-21T16:00:00 $dsa", [qw(-a 1600), @da],

    "--gres=gpu:2 --mem-per-gpu=123M $dsa", [qw(-l gpus=2 --mem-per-gpu=123M), @sa],
    "--gres=mps:300 --mem-per-gpu=124M $dsa", [qw(-l mps=300 --mem-per-gpu=124M), @sa],
    "$dba --gres=gpu:2 --cpus-per-gpu=2 $dsa", [@gda],
    # 3 gpus, 4ppn -> with ceil, 2 cpus per gpu, so 6 tasks per node also total tasks should go up
    "--nodes=2 --ntasks=12 --ntasks-per-node=6 --gres=gpu:3 --cpus-per-gpu=2 $dsa", [@gda3],
    "$dba --gres=mps:400 --cpus-per-gpu=1 $dsa", [@mda],
    "$dba --mem=2048M --gres=gpu:2 --cpus-per-gpu=2 $dsa", [qw(-l vmem=2gb), @gda],
    "--time=5 --gpus=3 --cpus-per-gpu=10 --mem-per-gpu=456M $dsa", [qw(-l walltime=4:4 --cpus-per-gpu=10 --mem-per-gpu=456M), @ga],
    );

=head1 test all commands in %comms hash

=cut

foreach my $cmdtxt (sort keys %comms) {
    my $arr = $comms{$cmdtxt};
    diag "args ", join(" ", @$arr);
    diag "cmdtxt '$cmdtxt'";

    @ARGV = (@$arr);
    my ($mode, $command, $block, $script, $script_args, $defaults) = make_command();
    diag "mode ", $mode || 0;
    diag "interactive ", ($mode & 1 << 1) ? 1 : 0;
    diag "dryrun ", ($mode & 1 << 2) ? 1 : 0;
    diag "command '".join(" ", @$command)."'";
    diag "block '$block'";

    is(join(" ", @$command), "$sbatch $cmdtxt", "expected command for '$cmdtxt'");
    is($script, 'script', "expected script $script for '$cmdtxt'");
    my @expargs = qw(arg1);
    push(@expargs, $1) if $cmdtxt =~ m/(X|Y)$/;
    is_deeply($script_args, \@expargs, "expected scriptargs ".join(" ", @$script_args)." for '$cmdtxt'");
    is_deeply($defaults, $defs, "expected defaults for '$cmdtxt'");
}

=head1 test submitfilter

=cut

# set submitfilter
$submitfilter = "/my/submitfilter";

@ARGV = (@da);
my ($mode, $command, $block, $script, $script_args, $defaults) = make_command($submitfilter);
diag "submitfilter command @$command";
my $txt = "$sbatch $dba";
is(join(" ", @$command), $txt, "expected command for submitfilter");

# no match
diag "no match command ", explain($command), " defaults ", explain($defaults), " no stdin";
$txt .= " -J script --chdir=$ENV{HOME} -e ".getcwd."/%x.e%A --export=NONE --get-user-env=60L -o ".getcwd."/%x.o%A";
my ($newtxt, $newcommand) = parse_script('', $command, $defaults);
is(join(" ", @$newcommand), $txt, "expected command after parse_script without eo");

# replace PBS_JOBID
# no -o/e/J
# insert shebang
{
    local $ENV{SHELL} = '/some/shell';
    my $stdin = "#\n#PBS -l nodes=123 -o stdout.\${PBS_JOBID}..\$PBS_JOBID\n#\n#PBS -e /abc -N def\ncmd -l foo -x bar\n";
    diag "replace PBS_JOBID command ", explain($command), " defaults ", explain($defaults), " stdin '$stdin'";
    ($newtxt, $newcommand) = parse_script($stdin, $command, $defaults);
    is(join(" ", @$newcommand),
       "$sbatch --nodes=2 --ntasks=8 --ntasks-per-node=4 --chdir=$ENV{HOME} --export=NONE --get-user-env=60L",
       "expected command after parse_script with eo");
    is($newtxt, "#!/some/shell\n#\n#SBATCH --nodes=123\n#PBS -o ".getcwd."/stdout.%A..%A\n#\n#PBS -e /abc -N def\ncmd -l foo -x bar\n",
       "PBS_JOBID replaced");
}

my $stdin = "#!/bin/something\n#PBS -l nodes=123:ppn=456:gpus=1 -o stdout -l mem=112233\n#\n#PBS -l gpus=2 -l mem=223344 -N def\ncmd\n";
($newtxt, $newcommand) = parse_script($stdin, $command, $defaults);
diag "replace PBS resource directives stdin '$stdin' newtxt '$newtxt'";
is($newtxt,
   "#!/bin/something\n#SBATCH --nodes=123 --ntasks=56088 --ntasks-per-node=456 --mem=0.107033729553223M --gres=gpu:1 --cpus-per-gpu=456\n".
   "#PBS -o ".getcwd."/stdout\n#\n#SBATCH --mem=0.212997436523438M --gres=gpu:2\n#PBS -N def\ncmd\n",
   "replaced PBS resource directives with SBATCH ones");

=head1 interactive job

=cut

@ARGV = ('-I', '-l', 'nodes=2:ppn=4', '-l', 'vmem=2gb');
($mode, $command, $block, $script, $script_args, $defaults) = make_command($submitfilter);
diag "interactive command @$command default ", explain $defaults;
$txt = "$dba --mem=2048M srun --pty --mpi=none --mem=0";
is(join(" ", @$command), "$salloc $txt", "expected command for interactive");
$script =~ s#^/usr##;
is($script, '/bin/bash', "interactive script value is the bash shell command");
is_deeply($script_args, ['-i', '-l'], 'interactive script args');
ok($mode & 1 << 1, "interactive mode");
ok(!($mode & 1 << 2), "no dryrun mode w interactive");
# no 'get-user-env' (neither for salloc where it belongs but requires root; nor srun)
is_deeply($defaults, {
    J => 'INTERACTIVE',
    export => 'USER,HOME,TERM',
    'cpu-bind' => 'none',
    chdir => $ENV{HOME},
}, "interactive defaults");

# no 'bash -i'
$txt = "$salloc -J INTERACTIVE $txt --chdir=$ENV{HOME} --cpu-bind=none --export=USER,HOME,TERM";
($newtxt, $newcommand) = parse_script(undef, $command, $defaults);
ok(!defined($newtxt), "no text for interactive job");
is(join(" ", @$newcommand), $txt, "expected command after parse with interactive");

=head1 qsub -d

=cut

my $dir = '/just/a/test';
@ARGV = ('-d', $dir);
($mode, $command, $block, $script, $script_args, $defaults) = make_command($submitfilter);
$txt = "--chdir=$dir";
my $cmdstr = join(' ', @$command);
ok(index($cmdstr, $txt) != -1, "$txt appears in: $cmdstr");
# make sure --chdir is only included once in the generated command (i.e. no more --chdir=$HOME)
my $count = ($cmdstr =~ /--chdir/g);
is($count, 1, "exactly one --chdir found: $count");

=head1 test parse_script for -j directive and if -e/-o directive is a directory

=cut

sub pst
{
    my ($stdin, $static_ARGV) = @_;
    diag "pst stdin '$stdin' static_argv ", explain $static_ARGV;
    my ($mode, $command, $block, $script, $script_args, $defaults, $destination) = make_command();
    my ($newtxt, $newcommand) = parse_script($stdin, $command, $defaults, $static_ARGV, $destination);
    my $txt = join(' ', @$newcommand);
    diag "pst return command txt '$txt' newscript\n$newtxt";
    return $txt, $newtxt;
}

$stdin = "#\n#PBS -j oe\ncmd\n";
$txt = " -e ";
($cmdstr, $newtxt) = pst($stdin);
is(index($cmdstr, $txt), -1, "With -j directive, \"$txt\" argument should not be in: $cmdstr");

$stdin = "#\n#PBS -e .\n#PBS -o output\ncmd\n";
$txt = "-e " . getcwd . "/./%";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($cmdstr, $txt), -1, "If -e directive is a directory, \"$txt\" argument should be in: $cmdstr");

$stdin = "#\n#PBS -o .\n#PBS -j oe\ncmd\n";
$txt = "-o " . getcwd . "/./%";
my $txt2 = " -e ";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($cmdstr, $txt), -1, "If -o directive is a directory and -j directive is present, \"$txt\" argument should be in: $cmdstr");
is(index($cmdstr, $txt2), -1, "If -o directive is a directory and -j directive is present, \"$txt2\" argument should not be in: $cmdstr");

$stdin = "";
$txt = "-o " . getcwd . "/./%";
@ARGV = ('-o', '.');
($cmdstr, $newtxt) = pst($stdin);
isnt(index($cmdstr, $txt), -1, "If -o argument is a directory, \"$txt\" argument should be in: $cmdstr");

$txt = "-e " . getcwd . "/./%";
@ARGV = ('-e', '.');
($cmdstr, $newtxt) = pst($stdin);
isnt(index($cmdstr, $txt), -1, "If -e argument is a directory, \"$txt\" argument should be in: $cmdstr");

sub generate
{
    my @array;
    my ($format, $comm_dir) = @_;
    mkdir "dir_${comm_dir}_dir";
    for my $e (" ", "-e dir_${comm_dir}_dir ", "-e $comm_dir ") {
        for my $o (" ", "-o dir_${comm_dir}_dir ", "-o $comm_dir ") {
            for my $j (" ", "-j oe ") {
                for my $N (" ",  "-N ${comm_dir}_name ") {
                    push(@array, sprintf($format, $e, $o, $j, $N));
                };
            };
        };
    };
    return @array
}

sub check_eo_test {
    my ($commandline, $stdin, $cmdstr, $getcwd, $oore) = @_;
    my $outorerr = "Output";
    if ($oore eq "e") {
        $outorerr = "Error";
    }
    my $name_check = sub {
        my $comm_or_std = $commandline;
        my $comm_or_std_txt = "commandline";
        if ($_[0] eq "stdin") {
            $comm_or_std = $stdin;
            $comm_or_std_txt = "directive";
        }
        if (index($comm_or_std, "-$oore dir_${comm_or_std_txt}_dir") != -1) {
            isnt(index($cmdstr, "-$oore $getcwd/dir_${comm_or_std_txt}_dir/"), -1,
                 "$outorerr should be in dir_${comm_or_std_txt}_dir directory\ncommandline: $commandline\nstdin: $stdin\ncmdstr: $cmdstr\n");
            if (index($commandline, "-N") != -1 ) {
                isnt(index($cmdstr, "-$oore $getcwd/dir_${comm_or_std_txt}_dir/commandline_name"), -1,
                     "Name of the file should be taken form command line\ncommandline: $commandline\nstdin: $stdin\ncmdstr: $cmdstr\n");
                is(index($cmdstr, "-$oore $getcwd/dir_${comm_or_std_txt}_dir/directive_name"), -1,
                   "Name of the file should be taken form command line, not from directive\ncommandline: $commandline\nstdin: $stdin\ncmdstr: $cmdstr\n");
            } else {
                if (index($stdin, "-N") != -1 ) {
                    isnt(index($cmdstr, "-$oore $getcwd/dir_${comm_or_std_txt}_dir/%x"), -1,
                         "Name of the file should be handled by Slurm\ncommandline: $commandline\nstdin: $stdin\ncmdstr: $cmdstr\n");
                }
            }
        }
    };
    if (index($commandline, "-$oore") != -1) {
        is(index($cmdstr, "-$oore $getcwd/directive"), -1,
           "If -$oore in commandline defined, then -$oore directive should be ignored\ncommandline: $commandline\nstdin: $stdin\ncmdstr: $cmdstr\n");
        if (index($commandline, "-$oore commandline") != -1) {
            isnt(index($cmdstr, "-$oore $getcwd/commandline"), -1,
                 "$outorerr name should be commandline\ncommandline: $commandline\nstdin: $stdin\ncmdstr: $cmdstr\n");
        }
        &$name_check("commandline");
    } else {
        if (index($stdin, "-$oore directive") != -1) {
            is(index($cmdstr, "-$oore $getcwd/directive"), -1,
               "$outorerr name handled by slurm plugin\ncommandline: $commandline\nstdin: $stdin\ncmdstr: $cmdstr\n");
        }
        &$name_check("stdin");
    }
}

# run this in a tempdir
my $here = getcwd;
my $tempdir = tempdir( CLEANUP => 1 );
chdir($tempdir);

my @commandlines = generate("%s %s %s %s", "commandline");
my @stdins = generate("#!/bin/bash\n#PBS %s\n#PBS %s\n#PBS %s\n#PBS %s\ncmd\n", "directive");
my $getcwd = getcwd;
for my $commandline (@commandlines) {
    for $stdin (@stdins) {
        my @static_ARGV = split ' ', $commandline;
        @ARGV = @static_ARGV;
        ($cmdstr, $newtxt) = pst($stdin, \@static_ARGV);
        check_eo_test($commandline, $stdin, $cmdstr, $getcwd, "o");
        if (index($commandline, "-j oe") != -1 || index($stdin, "-j oe") != -1) {
            is(index($cmdstr, "-e "), -1,
               "If -j command line option or directive is defined, -e should not be defined\ncommandline: $commandline\nstdin: $stdin\ncmdstr: $cmdstr\n");
        } else {
            check_eo_test($commandline, $stdin, $cmdstr, $getcwd, "e");
        }
        if (index($commandline, "-N") != -1 ) {
            isnt(index($cmdstr, "-J commandline_name"), -1,
                 "Name should be taken form command line\ncommandline: $commandline\nstdin: $stdin\ncmdstr: $cmdstr\n");
            is(index($cmdstr, "-J directive_name"), -1,
               "Name should be taken form command line, not from directives\ncommandline: $commandline\nstdin: $stdin\ncmdstr: $cmdstr\n");
        } else {
            if (index($stdin, "-N") != -1 ) {
                is(index($cmdstr, "-J directive_name"), -1,
                   "Name is handled by Slurm\ncommandline: $commandline\nstdin: $stdin\ncmdstr: $cmdstr\n");
            }
        }
    };
};

# change back
chdir($here);


$stdin = "";
$txt = "--x11";
@ARGV = ('-X');
($cmdstr, $newtxt) = pst($stdin);
isnt(index($cmdstr, $txt), -1, "If -X option used, \"$txt\" option should be in: $cmdstr");

$stdin = "#!/usr/bin/bash\n#PBS -X\necho\n";
$txt = "--x11";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($cmdstr, $txt), -1, "If -X directive used, \"$txt\" option should be in: $cmdstr");

$stdin = "";
$txt = "#PBS -l walltime=72:00:00";
@ARGV = ('-q', 'long');
($cmdstr, $newtxt) = pst($stdin);
isnt(index($newtxt, $txt), -1, "If -q long option used, \"$txt\" directive should be in: $newtxt");

$stdin = "#!/usr/bin/bash\n#PBS -q long\necho\n";
$txt = "#PBS -l walltime=72:00:00";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($newtxt, $txt), -1, "If -q long directive used, \"$txt\" directive should be in: $newtxt");

local $ENV{SLURM_CLUSTERS} = "kluster";
$stdin = "";
$txt = "--partition $ENV{SLURM_CLUSTERS}_special";
@ARGV = ('-q', 'special');
($cmdstr, $newtxt) = pst($stdin);
isnt(index($cmdstr, $txt), -1, "If -q  $ENV{SLURM_CLUSTERS}_special option used, \"$txt\" option should be in: $cmdstr");

$stdin = "#!/usr/bin/bash\n#PBS -q special \necho\n";
$txt = "--partition $ENV{SLURM_CLUSTERS}_special";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($cmdstr, $txt), -1, "If -q $ENV{SLURM_CLUSTERS}_special directive used, \"$txt\" option should be in: $cmdstr");

$stdin = "";
$txt = "salloc";
$txt2 = "--partition $ENV{SLURM_CLUSTERS}_special";
my $txt3 = "srun";
@ARGV = ('-q', 'special', '-I');
($cmdstr, $newtxt) = pst($stdin);
ok(index($cmdstr, $txt) < index($cmdstr, $txt2), "$txt should be before $txt2 in \"$cmdstr\"");
ok(index($cmdstr, $txt2) < index($cmdstr, $txt3), "$txt2 should be before $txt3 in \"$cmdstr\"");

local $ENV{VSC_HOME} = '/home/path';
$txt = '/home/path/test.foo';
$stdin = "#!/usr/bin/bash\n#PBS -o \${VSC_HOME}/test.foo \necho\n";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($newtxt, $txt), -1, "If #PBS -o \${VSC_HOME}/test.foo used in the submit script, it has to be translated to \"$txt\" in: $newtxt");

local $ENV{MAIL} = 'e@mail.com';
$stdin = "#!/usr/bin/bash\n#PBS -M \$PBS_O_MAIL \necho\n";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($newtxt, $ENV{MAIL}), -1, "If #PBS -M \$PBS_O_MAIL used in the submit script, it has to be translated to \"$ENV{MAIL}\" in: $newtxt");

local $ENV{VSC_DATA} = '/data/path';
local $ENV{VSC_INSTITUTE_CLUSTER} = 'pokemon';
$txt = '/data/path/pokemon/test.foo';
$stdin = "#!/usr/bin/bash\n#PBS -o \$VSC_DATA/\$VSC_INSTITUTE_CLUSTER/test.foo \necho\n";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($newtxt, $txt), -1, "If #PBS -o \$VSC_DATA/\$VSC_INSTITUTE_CLUSTER/test.foo used in the submit script, it has to be translated to \"$txt\" in: $newtxt");

$stdin = "#!/usr/bin/bash\n#PBS -t 1\necho\n";
$txt = "-%a";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($cmdstr, $txt), -1, "Array extension \"$txt\" should be in \"$cmdstr\"");

$stdin = "#!/usr/bin/bash\necho\n";
my @staticARGV = ('-t', '1');
@ARGV = @staticARGV;
$txt = "-%a";
($cmdstr, $newtxt) = pst($stdin, \@staticARGV);
isnt(index($cmdstr, $txt), -1, "Array extension \"$txt\" should be in \"$cmdstr\"");

$stdin = "#!/usr/bin/bash\n#PBS -t 1\n#PBS -o OutputFile\necho\n";
@ARGV = ('-e', 'ErrorFile');
$txt = "-%a";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($cmdstr, $txt), -1, "Array extension \"$txt\" should be in \"$cmdstr\"");
isnt(index($newtxt, $txt), -1, "Array extension \"$txt\" should be in \"$newtxt\"");

$stdin = "#!/usr/bin/bash\n#PBS -o OutputFile\necho\n";
@staticARGV = ('-t', '1', '-e', 'ErrorFile');
@ARGV = @staticARGV;
$txt = "-%a";
($cmdstr, $newtxt) = pst($stdin, \@staticARGV);
isnt(index($cmdstr, $txt), -1, "Array extension \"$txt\" should be in \"$cmdstr\"");
isnt(index($newtxt, $txt), -1, "Array extension \"$txt\" should be in \"$newtxt\"");

$stdin = "#!/usr/bin/bash\n#PBS -W x=advres:ReSeV-NAME-directive\necho\n";
$txt = "--reservation ReSeV-NAME-directive";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($cmdstr, $txt), -1, "Request for reservation \"$txt\" should be in \"$cmdstr\"");

$stdin = "#!/usr/bin/bash\necho\n";
@ARGV = ('-W', 'x=ADVRES:ReSeV-NAME-commandline');
$txt = "ReSeV-NAME-commandline";
($cmdstr, $newtxt) = pst($stdin);
isnt(index($ENV{SBATCH_RESERVATION}, $txt), -1, "\$SBATCH_RESERVATION should be \"$txt\"");
delete $ENV{SBATCH_RESERVATION};

$stdin = "#!/usr/bin/bash\n#PBS -W x=advres:ReSeV-NAME-directive2\necho\n";
@staticARGV = ('-W', 'x=ADVRES:ReSeV-NAME-commandline2');
@ARGV = @staticARGV;
$txt = "--reservation ReSeV-NAME-directive2";
$txt2 = "ReSeV-NAME-commandline2";
($cmdstr, $newtxt) = pst($stdin, \@staticARGV);
is(index($cmdstr, $txt), -1, "Request for reservation \"$txt\" should not be in \"$cmdstr\"");
isnt(index($ENV{SBATCH_RESERVATION}, $txt2), -1, "\$SBATCH_RESERVATION should be \"$txt2\"");
delete $ENV{SBATCH_RESERVATION};


done_testing();
