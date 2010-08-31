#
#    Common: Shared library for voice-based applications.
#
#    Copyright (C) 2010 Nokia Corporation.
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Affero General Public License as
#    published by the Free Software Foundation, either version 3 of the
#    License, or (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Affero General Public License for more details.
#
#    You should have received a copy of the GNU Affero General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#    Authors: Billy Odero, Jonathan Ledlie

package Nokia::Common::Tools;
use Exporter;
@ISA = ('Exporter');
@EXPORT = ('get_max_results_to_listen_to', 'walk_query_results','dtmf_dispatch_static','dtmf_dispatch_dynamic', 'write_pid','reap_old_self','stream_file', 'say_number', 'get_channel_desc','db_connect','user_has_hungup','get_hash_file','get_seconds_remaining_count','db_disconnect', 'place_call', 'codec', 'get_large_number', 'get_unchecked_large_number', 'get_unchecked_small_number', 'get_yes_no_option', 'get_dtmf_input','get_small_number','mv_tmp_to_comment_dir', 'mv_tmp_to_post_dir', 'mv_tmp_to_names_dir','mv_tmp_to_status_dir', 'mv_tmp_to_dir', 'record_file', 'get_max_uint','request_attendant', 'speech_or_dtmf_input', 'init_user', 'create_user', 'get_user_id', 'get_user_name','set_user_name', 'play_random', 'dtmf_quick_jump', 'init_tools', 'get_callcount', 'rnd_alphanum', 'sms_enqueue', 'unlink_file', 'unlink_tmp_file', 'check_end_network_modify_menu', 'get_network_of_friendship', 'select_network_menu', 'set_nickname_file', 'get_nickname_file');


use strict;
use DBI;
use Data::Dumper;
use IO::Socket;
use File::Copy;
use Nokia::Common::Stamp;
use Nokia::Common::Sound;
use Nokia::Common::Phone;
use Math::Random qw(random_uniform_integer);
use LWP;
use URI;
use LWP::UserAgent;

######################################################################

my $calldir = $ENV{"NASI_OUTGOING"};
my $cbCount = 0;

my $HASH_FILE_LENGTH = 16;
my $MAX_DTMF_PROMPTS = 2;
my $DEFAULT_TIMEOUT = 5000;
my $MAX_RESULTS_TO_LISTEN_TO = 60;

# This can be an in-memory file system, for short-lived files
my $tmp_dir = $ENV{"NASI_TMP"};
my $tmp_rec_dir = $tmp_dir.'/record/';

my $posts_dir = '/data/posts/';
my $names_dir = '/data/names/';
my $comments_dir = '/data/comments/';
my $status_dir = '/data/status/';
my $nicknames_dir = '/data/names/';

######################################################################
#

sub codec {
# record files on the file system using this codec
# TODO would it be better to use 'sln'?
# Can 'sln' files be played through a web browser easily?

    return 'gsm';
}

######################################################################

sub get_max_uint {

    return 4294967295;

}

######################################################################
# Called on startup.
# Use for any initialization of this module

sub init_tools {
    my ($self) = @_;

}

######################################################################
sub play_random {
    my ($self, $msg, $random_key) = @_;

    my $MAX_RANDOM_MSGS = 5;

    # Thought about having a cache for the random number generator
    # But this would need to be locked across threads,
    # and therefore probably more expensive than just creating them
    # one at a time.

    my $random_msg = 
	sprintf ("$random_key-%02d", 
		 Math::Random::random_uniform_integer (1, 1, $MAX_RANDOM_MSGS));

    #$self->log (4, "r $random_msg");

    my $dtmf = $self->agi->stream_file([&msg($self,$random_msg),$msg], "*#", "0");
    return $dtmf;
}

######################################################################
# Ask the user once if he wants to jump somewhere
# Assumes press 1 to go there.

sub dtmf_quick_jump {
    my ($self, $jump_fn, $prompt) = @_;


    $self->log(4, "First Jump");

    my %words = ('prompt' => $prompt);

    my %dispatch = (1 => $jump_fn,
	'max_prompts' => 1);

    my $res = &dtmf_dispatch ($self, \%words, \%dispatch, '1*');

    $self->log (4, "dtmf_quick_jump res $res");

    return $res;
    
}

######################################################################

sub dtmf_dispatch_static {
    my ($self, $words, $dispatch, $digits) = @_;

    while (1) {
	my $ret = &dtmf_dispatch ($self, $words, $dispatch, $digits);
	if ($ret eq 'hangup' || $ret eq 'cancel' || $ret eq 'timeout') { return $ret; }
    }
}


sub dtmf_dispatch {
    my ($self, $words, $dispatch, $digits) = @_;

    die if (!defined($words));
    die if (!defined($words->{'prompt'}));
    die if (!defined($dispatch));
    die if ($digits !~ /\*/);

    my @prompt_list = ();
    my $last_prompt = $words->{'prompt'};

    if (ref($words->{'prompt'}) eq "ARRAY") {
	print STDERR ("dtmf_dispatch prompt is array\n");
	my @prompts = @{$words->{'prompt'}};
	my $p = 0;
	for (; $p < $#prompts; $p++) {
	    push (@prompt_list, $prompts[$p]);
	    #print STDERR ("prompt_list gets ".$prompt->[$p]."\n");
	}
	$last_prompt = $prompts[$p];
	print STDERR ("last prompt is ".$prompts[$p]."\n");
    }

    # words->pre = say first time through
    # words->prompt = tell user what to press for what action
    # words->post = say if no input was given

    my $max_prompts = $MAX_DTMF_PROMPTS;
    if (defined($dispatch->{max_prompts})) {
	$max_prompts = $dispatch->{max_prompts};
    }

    $self->log (4, "starting dtmf_dispatch digits $digits");

    my $dtmf = 0;
    if (defined($words->{'pre'})) {
	$dtmf = $self->agi->stream_file
	    ($words->{'pre'}, "$digits", "0");
    }

    for (my $i = 0; $i < $max_prompts && defined($dtmf)
	 && $dtmf == 0; $i++) {

	if (&user_has_hungup($self)) { return 'hangup'; }

	#print STDERR ("A dtmf $dtmf\n");

	if ($#prompt_list >= 0) {
	    foreach (my $p = 0; $p <= $#prompt_list &&
		     defined($dtmf) && $dtmf == 0; $p++) {
		$dtmf =
		    $self->agi->stream_file($prompt_list[$p], "$digits", "0");
	    }
	}

	if (defined($dtmf) && $dtmf == 0) {
	    $dtmf = $self->agi->get_option
		($last_prompt,"$digits", $DEFAULT_TIMEOUT);
	}

	#print STDERR ("B dtmf $dtmf\n");

	# say something on timeout if we have something to say
	if ($dtmf == 0 && defined($words->{'post'})) {
	    $dtmf = $self->agi->get_option($words->{'post'},
					   "$digits", $DEFAULT_TIMEOUT);

	    #print STDERR ("C dtmf $dtmf\n");
	}

	#print STDERR ("dtmf loop $i dtmf $dtmf\n");

    }

    #print STDERR ("dtmf_dispatch ended for loop dtmf $dtmf\n");

    # user did not give any input in time alloted
    if (!defined($dtmf) || $dtmf < 0) {
	$self->log (3, "user hung up");	
	return 'hangup';
    }
    if ($dtmf == 0) {
	$self->log (3, "timed out");	
	return 'timeout';
    }

    my $input = chr($dtmf);

    $self->log (3, "post-loop input $input");

    if ($input ne '*') {
	#$self->log (3, "jump to fn?");
	die if (!defined($dispatch->{$input}));
	#$self->log (3, "yes: jump to fn");
	my $function = $dispatch->{$input};


	my $ret = $function->($self);

	if (!defined($ret)) {
	    $self->log (4, "func returned undef");

	    return 'ok';
	} else {
	    $self->log (4, "func returned $ret");
	}

	return $ret;

    } else {
	$self->log (3, "user entered *");
	return 'cancel';
    }

    # we will return here after running the dispatch function

    return 'ok';

}



######################################################################

sub dtmf_dispatch_dynamic {
    my ($self, $dynamic_prompt_fn) = @_;

    while (1) {
	my %word_hash = ();
	my %dispatch_hash = ();
	my $digits = '';
	my $words = \%word_hash;
	my $dispatch = \%dispatch_hash;

	&$dynamic_prompt_fn ($self, $words, $dispatch, \$digits);


	my $ret = &dtmf_dispatch ($self, $words, $dispatch, $digits);
	$self->log (4, "dtmf_dispatch ret $ret");
	if ($ret eq 'hangup') { return $ret; }
    }

}



######################################################################

sub get_yes_no_option {
    my ($self, $prompt) = @_;

    # return 'no' for no
    # return 'yes' for yes
    # return 'timeout' for timeout or hangup

    die if (!defined($prompt));

    my $dtmf = 0;
    my $input = -1;

    my @prompt_list = ();
    my $last_prompt = $prompt;

    if ($prompt eq "ARRAY") {
	my @prompts = @{$prompt};
	my $p = 0;
	for (; $p < $#prompts; $p++) {
	    push (@prompt_list, $prompts[$p]);
	}
	$last_prompt = $prompts[$p];
    }

    $self->log (4, "starting get_yes_no_option");

    for (my $i = 0; $i < $MAX_DTMF_PROMPTS && $dtmf == 0; $i++) {

	#$self->log (4, "A dtmf loop $i dtmf $dtmf\n");

	if ($#prompt_list >= 0) {
	    foreach (my $p = 0; $p <= $#prompt_list &&
		     defined($dtmf) && $dtmf == 0; $p++) {
		$dtmf =
		    $self->agi->stream_file($prompt_list[$p], "12*", "0");
	    }
	}

	if (defined($dtmf) && $dtmf == 0) {
	    $dtmf = $self->agi->get_option
		($prompt, "12*", 250);
	}

	#$self->log (4, "B dtmf loop $i dtmf $dtmf\n");

	if (defined($dtmf) && $dtmf == 0) {
	    $dtmf = $self->agi->get_option
		(&msg($self,'yes-press-one-no-press-two'),
		 "12*", $DEFAULT_TIMEOUT); 
   	}

	#$self->log (4, "B dtmf loop $i dtmf $dtmf\n");
    }

    # user did not give any input in time alloted
    if (!defined($dtmf) || $dtmf < 0) {
	$self->log (3, "user hung up");	
	return 'hangup';
    }

    if ($dtmf == 0) {
	$self->log (3, "timed out");	
	return 'timeout';
    }

    $self->log (4, "ended for loop dtmf $dtmf\n");

    $input = chr($dtmf);

    $self->log (3, "post-loop input $input");

    if ($input eq '1') {
	return 'yes';
    } elsif ($input eq '2') {
	return 'no';
    } elsif ($input eq '*') {
	return 'cancel';
    }

    die ("Should not be reached");

}

######################################################################

sub get_large_number {
    my ($self, $prompt) = @_;
    my $number = &get_and_check_number ($self, $prompt, "0", 1);
    $self->log (4, "get_large_number returning $number");
    return $number;
}

######################################################################

sub get_unchecked_large_number {

    my ($self, $prompt, $number_list) = @_;

    for (my $p = 0; $p < $MAX_DTMF_PROMPTS; $p++) {

	my $loop = 0;
	my $number = '';
	my $timeout = 0;

	while (!$timeout) {

	    my $dtmf = 0;

	    if ($loop == 0) {
		my $allDigits = "0123456789*#";
		if (ref($prompt) eq "ARRAY") {
		    # play the first prompts only the first time through
		    if ($p == 0) {
			for (my $s = 0; defined($dtmf) && $dtmf == 0 &&  $s < $#$prompt; $s++) {
			    $dtmf = $self->agi->stream_file ($prompt->[$s],$allDigits,"0"),
			}
		    }
		    # play the last prompt everytime (including after timeouts)
		    # unless the user has already cut us off
		    if (defined($dtmf) && $dtmf == 0) {
			$dtmf = $self->agi->stream_file ($prompt->[$#$prompt],$allDigits,"0"),
		    }
		} else {
		    # if there's only one prompt, just play it everytime
		    $dtmf = $self->agi->stream_file ($prompt,$allDigits,"0"),
		}
	    }

	    if (defined($dtmf) && $dtmf == 0) {
		# wait a little after we've played a prompt for the user to enter something
		# if he hasn't entered anything already
		$dtmf = $self->agi->wait_for_digit(3000);
	    }

	    if (!defined($dtmf) || $dtmf < 0) {

		return 'hangup';

	    } elsif ($dtmf > 0) {
		my $input = chr($dtmf);
		#print STDERR "got input $input\n";

		if ($input eq '*') {
		    return 'cancel';
		} elsif ($input eq '#') {
		    if ($number eq '') {
			return 'cancel';
		    }
		    return $number;
		} else {
		    $number .= $input;
		    push (@$number_list, $input);
		}
	    } else {
		# timed out, did user enter any digits?

		if (length($number) > 0) {
		    return $number;
		} else {
		  # prompt the user again
		  $timeout = 1;
		}
	    }

	    $loop++;
	}

    }

    return 'timeout';
}

######################################################################

sub get_small_number {
    my ($self, $prompt, $digits) = @_;
    return &get_and_check_number ($self, $prompt, $digits, 0);
}

######################################################################

sub get_unchecked_small_number {
    my ($self, $prompt, $digits) = @_;

    my $dtmf = &get_dtmf_input ($self, $prompt, $digits);

    if ($dtmf =~ /^\d+$/ && $dtmf > 0) {
	my $number = chr ($dtmf);
	return $number;
    }

    # This can return strings

    return $dtmf;
}

######################################################################

sub get_and_check_number {
    my ($self, $prompt, $valid_numbers, $is_large_number) = @_;

    $self->log (4, "starting get_and_check_number");

    my $number = 0;
    for (my $i = 0; $i < $MAX_DTMF_PROMPTS &&
	 defined($number) && $number >= 0; $i++) {

	my @number_list = ();

	if ($is_large_number) {
	    # returns 0, 1, ...
	    # or -1 on error
	    $number = &get_unchecked_large_number ($self, $prompt, \@number_list);
	    $self->log (4, "in get_and_check_number, get_unchecked_large_number returned $number");
	} else {
	    $number = &get_unchecked_small_number ($self, $prompt, $valid_numbers);
	    $self->log (4, "in get_and_check_number, get_unchecked_small_number returned $number");
	    $number_list[0] = $number;
	}

	$self->log (4, "get_dtmf_input returned number $number");

	if ($number eq 'timeout' || $number eq 'hangup' || $number eq 'cancel') {
	  return $number;
	}

	if ($number >= 0) {

	    my $input = 0;

	    my $digits = '12*';

	    # If user enters 2, we break out of here and
	    # let him enter a new number.

	    for (my $j = 0; $j < $MAX_DTMF_PROMPTS && $input ne '2'; $j++) {

		my $dtmf = $self->agi->stream_file(&msg($self,'you-entered'), "$digits", "0");

		if (defined($dtmf)) {
		    $self->log (4, "after you_entered dtmf $dtmf");
		} else {
		    $self->log (4, "after you_entered dtmf NULL");
		}

		if ($dtmf == 0) {

		    #my @number_as_array = ();
		    for (my $n = 0; $n <= $#number_list && $dtmf == 0; $n++) {
			$dtmf = $self->agi->stream_file
			    (&msg($self,"digits/$number_list[$n]"),
			    "$digits", "0");

			$self->log (4, "saying number $n dtmf $dtmf");
		    }

		    $self->log (4, "after say_number dtmf $dtmf");

		    if ($dtmf == 0) {

		      $dtmf = $self->agi->get_option 
			(&msg($self,'if-correct'), "$digits", $DEFAULT_TIMEOUT);

		      $self->log (4, "after get_option dtmf $dtmf");
		    }
		}

		$self->log (4, "before first return dtmf $dtmf");

		if (!defined($dtmf) || $dtmf < 0) {
		    $self->log (4, "user hungup get_and_check_number");
		    return 'hangup';
		} elsif ($dtmf == 0) {
		    $self->log (4, "user timed out get_and_check_number");
		    return 'timeout';
		}

		$input = chr ($dtmf);
		if ($input eq '1') {
		    $self->log (4, "get_and_check_number user picked $number");
		    return $number;
		} elsif ($input eq '*') {
		    $self->log (4, "user quit get_and_check_number");
		    return 'cancel';
		}

	    }
	}

    }

    $self->log (4, "leaving get_and_check_number");

    return 'timeout';
}

######################################################################

sub get_dtmf_input {
    my ($self, $prompt, $digits) = @_;

    # returns number input

    # prompt can be either a ref to an array of prompts or just the one prompt
    # do the right thing in either case

    # get_option only takes one file to stream (contrary to the documentation).
    # stream_file does not take a timeout.

    $self->log (4, "starting get_dtmf_number");

    die if (!defined($prompt));

    my $dtmf = 0;
    my $input = -1;

    my @prompt_list = ();
    my $last_prompt = $prompt;

    if (ref($prompt) eq "ARRAY") {
	#print STDERR ("prompt is array\n");
	my $p = 0;
	for (; $p < $#$prompt; $p++) {
	    push (@prompt_list, $prompt->[$p]);
	    #print STDERR ("prompt_list gets ".$prompt->[$p]."\n");
	}
	$last_prompt = $prompt->[$p];
	print STDERR ("last prompt is ".$prompt->[$p]."\n");
    }

    # Note that there is no advantage in sending in the sound files
    # in [x,y,z] format because
    # the underlying command does the looping anyway.

    for (my $i = 0; $i < $MAX_DTMF_PROMPTS && defined($dtmf) && $dtmf == 0; $i++) {

	# If we have a series of prompts, loop through them first
	if ($#prompt_list >= 0) {
	    foreach (my $p = 0; $p <= $#prompt_list &&
		     defined($dtmf) && $dtmf == 0; $p++) {
		$dtmf =
		    $self->agi->stream_file($prompt_list[$p], "$digits", "0");
	    }
	}

	#print STDERR ("A dtmf loop $i dtmf $dtmf\n");

	# With the last prompt, wait a bit for input
	# before we start looping again
	if (defined($dtmf) && $dtmf == 0) {

	    $dtmf = 
		$self->agi->get_option
		($last_prompt,"$digits", $DEFAULT_TIMEOUT); 
	    #print STDERR ("B dtmf loop $i dtmf $dtmf\n");
	}
    }

    #print STDERR ("ended for loop dtmf $dtmf\n");

    # user did not give any input in time alloted
    if (!defined($dtmf) || $dtmf < 0) {
	$self->log (3, "user hung up");	
	return 'hangup';
    }

    if ($dtmf == 0) {
	$self->log (3, "timed out");	
	return 'timeout';
    }

    $input = chr($dtmf);

    if ($input eq '*') {
	return 'cancel';
    }
    return $dtmf;

}

######################################################################

sub speech_or_dtmf_input {
    my ($self, $prompt, $grammar_file, $digits) = @_;

    # since we are going to keep all of these utterances for safe keeping
    # we'd better put them in a daily directory

    my $file_prefix = '/data/utter/'.&year_month_day_dir.'/'.&rnd_alphanum ($HASH_FILE_LENGTH);


    my $beep = 0;
    my $res = $self->agi->record_file ($file_prefix, 'wav', "$digits", 5000,'0', $beep, 1500);
    $self->log (3, "record file $res");

    if ($res > 0) {
	return chr($res);
    } elsif ($res < 0) {
	# error condition
	return '-1';
    }

    # take the recorded file and send it to the recognizer

    # TODO make more efficient with pipes, fifo, locks, etc.

    my $wav_file = $file_prefix.'.wav';
    my $sr_config_file = $file_prefix.'.cfg';
    my $sr_in_file = $file_prefix.'.srin';
    my $sr_out_file = $file_prefix.'.srout';
    open CFG, ">$sr_config_file" or die ("Cannot open sr config file $sr_config_file");
    print CFG "[FILES]\n";
    print CFG "VocabularyFile=$grammar_file\n";
    print CFG "MsgInFile=$sr_in_file\n";
    print CFG "ModelsFile=$self->{language_model}\n";
    print CFG "MsgOutFile=$sr_out_file\n";

    # okay.  a bit ugly.

    print CFG "[MODE]\nDensFrameRate=1\nFeatureMode=FILE_SAMPLES\nTimeOutEnd=4000\n";
    print CFG "PronunciationSize=1000\nDensTopRate=10000\nUTF8EncodedChar=1\n";
    print CFG "KeyPress=-1\nLidNbest=4\nTimeOutMin=1000\nNoiseSnr=5\nNoiseSnrRange=20\n";
    print CFG "NBest=5\n\n[LANG]\n";

    close CFG;

    my $default_in_lab = $ENV{NASI_HOME}.'/sr/in.lab';
    open MSGIN, ">$sr_in_file" or die ("Cannot open sr in file $sr_in_file");
    print MSGIN "msg_RECOGNITION_STATE in $wav_file lab $default_in_lab res foo usr bar\n";
    close MSGIN;

    my $cmd = $ENV{NASI_HOME}."/sr/sr $sr_config_file";
    $self->log (3, "running $cmd");

    # TODO check that this ran ok?
    system ($cmd);

    open MSGOUT, "$sr_out_file" or die ("Cannot open sr out file $sr_out_file");
    my $score = 0;
    my $keyword = '';
    while (my $line = <MSGOUT>) {
	# Result   1      score   877.99 [acc]    alexander_cooper
	if ($line =~ /Result\s+1\s+/) {
	    my (@res) = split (/\s+/,$line);
	    $score = $res[3];
	    $keyword = $res[5];
	}
    }
    close MSGOUT;

    $self->log (3, "score $score keyword $keyword");
    return $keyword;
}

######################################################################
sub request_attendant {
    my ($self) = @_;

    my $number = &get_unchecked_small_number
	($self, 
	 &msg($self,'please-press-0-to-connect-to-an-operator-or-hang-up-to-end-the-call'),
	 '0');

    if ($number == 0) {
	$self->agi->set_variable("ATTENDANT","connect");
    }
}

######################################################################

sub get_max_results_to_listen_to {
    return $MAX_RESULTS_TO_LISTEN_TO;
}

######################################################################

sub walk_query_results {
    my ($self) = @_;

    my $dtmf = 0;
    if ($self->{server}{query_sth}->rows <= 0) {
	$dtmf = $self->agi->stream_file
	    (&msg($self,"sorry-nothing-matches"),"*#","0");
    } elsif ($self->{server}{query_sth}->rows > $MAX_RESULTS_TO_LISTEN_TO) {
	$dtmf = $self->agi->stream_file
	    (&msg($self,"sorry-there-are-too-many-results-for-your-search-please-go-back-and-add-some-criteria"),"*#","0");
    } else {
	my $tuples = $self->{server}{query_sth}->
	    fetchall_arrayref({ post_id => 1, title_file => 1,
				desc_file => 1, contact_file => 1});


	$dtmf = $self->agi->stream_file(&msg($self,'walk-query-results-long'),"*#","0");	

	my $digits = "9743160*#";
	my $posts_dir = '/data/posts/';
	my $done = 0;

	for (my $t = 0; $t <= $#$tuples; $t++) {
	    if (defined($tuples->[$t])) {
		print STDERR "t $t is defined\n";
	    }
	}

	for (my $t = 0; $t <= $#$tuples && !$done &&
	     defined($dtmf) && $dtmf >= 0; $t++) {
	    my $tuple = $tuples->[$t];

	    print STDERR "tuple $tuple->{post_id}\n";

	    $dtmf = $self->agi->get_option
		($posts_dir.$tuple->{title_file},"$digits", 2500);

	    while (defined($dtmf) && $dtmf > 0 && !$done) {

		my $input = chr ($dtmf);
		$dtmf = 0;

		if ($input eq '9') {

		    # Play the user more detail
		    # If he doesn't do anything, continue on to the next entry

		    $dtmf = $self->agi->stream_file
			([&msg($self,'beep'),$posts_dir.$tuple->{desc_file},
			  &msg($self,'beep')], "$digits", "0");

		    if (defined($dtmf) && $dtmf == 0) {

			$dtmf = $self->agi->get_option
			    ($posts_dir.$tuple->{contact_file},"$digits", 2500);
		    }

		} elsif ($input eq '7') {

		    # User is NOT interested in this one

		    if (!defined($self->{query}->{rejected})) {
			my %rejected_hash = ();
			$self->{query}->{rejected} = \%rejected_hash;
		    }
		    my $rejected = $self->{query}->{rejected};
		    $rejected->{$tuple->{post_id}} = 1;
		    &tell_user_message ($self, &msg($self,'rejecting-this-posting'));

		} elsif ($input eq '#') {

		    # User IS interested in this one

		    if (!defined($self->{query}->{saved})) {
			my %saved_hash = ();
			$self->{query}->{saved} = \%saved_hash;
		    }
		    my $saved = $self->{query}->{saved};
		    $saved->{$tuple->{post_id}} = 1;
		    &tell_user_message ($self, &msg($self,'saving-this-posting'));

		} elsif ($input eq '4') {

		    # repeat the posting
		    $t--;
		    if ($t < 0) { $t = 0; }
		    &tell_user_message ($self, &msg($self,'repeat'));

		} elsif ($input eq '3') {

		    # skip ahead to the next posting

		    # do nothing

		    &tell_user_message ($self, &msg($self,'skip'));



		} elsif ($input eq '1') {

		    # jump backward

		    $t-=2;
		    if ($t < 0) { $t = 0; }

		    &tell_user_message ($self, &msg($self,'jump-back'));

		} elsif ($input eq '6') {

		    # flag as inappropriate

		} elsif ($input eq '0') {

		    # hear the directions
		    $dtmf = $self->agi->get_option
			(&msg($self,'walk-query-results-brief'),"$digits", 4000);
		    
		    # will go to the next one on no input
		    # or will act on it is there is input

		} elsif ($input eq '*') {

		    $done = 1;

		}
	    }
	}
    }

    if (!defined ($dtmf) || $dtmf < 0) {
	return -1;
    }
    return 0;
}

sub tell_user_message {
    my ($self, $msg) = @_;

    my $dtmf = $self->agi->stream_file
	($msg, "*#", "0");
    $self->agi->wait_for_digit (1500);
}

######################################################################

sub record_file {

    # Cleanly record a file to the temp filesystem,
    # letting the user play it back and re-record it.

    # Return the relative pathname of the file if successul
    #  (relative to the temp filesystem, which is kept in memory).

    # Delete the file if the user cancels or hangs up.

    # Message should be something like: record your X at the beep

    # Length_in_seconds is the maximum time the user is given for the recording.

    my ($self, $instructions_prompt, $length_in_seconds,
	$redo_prompt, $delete_on_hangup) = @_;

    $self->log (4, "start record_file");

    if (!defined ($redo_prompt)) {
	$redo_prompt = &msg($self,'to-keep-your-recording');
    }
    if (!defined($delete_on_hangup)) {
	$delete_on_hangup = 1;
    }

    my $hash = &rnd_alphanum ($HASH_FILE_LENGTH);

    $self->log (4, "record_file rnd alphanum $hash");

    my $SECONDS_OF_SILENCE = 3;
    my $tmp_record_file_no_codec = $tmp_rec_dir.$hash;
    my $tmp_record_file_w_codec = $tmp_rec_dir.$hash.'.'.&codec();
    my $tmp_record_file_wav_codec = $tmp_rec_dir.$hash.'.wav';

    my $res = '';
    my $silence_loop = 0;

    while ($res eq '') {

	my $dtmf = $self->agi->stream_file ($instructions_prompt, "*#","0");

	&unlink_file ($self, $tmp_record_file_w_codec);

	$self->log (4, "about to record to $hash");

	# record the file in wav format
	# but this is converted to gsm
	# by the time we have cleaned up the file
	
	if (defined($dtmf) && $dtmf >= 0 && chr($dtmf) ne '*') {

	    $dtmf = $self->agi->record_file
		($tmp_record_file_no_codec, 'wav', '*#0123456789', 
		 $length_in_seconds*1000, '0', 0, $SECONDS_OF_SILENCE);

	}

	if (!defined($dtmf) || $dtmf < 0) {
	    $res = 'hangup';
	} elsif (chr($dtmf) eq '*' || !-e$tmp_record_file_wav_codec) {
	    $res = 'cancel';
	}

	if (defined($dtmf)) {
	    $self->log (4, "recorded file $hash result $dtmf");
	} else {
	    $self->log (4, "recorded file $hash result undef");
	}

	my $rerecord = 0;

	if ($res ne 'cancel' && $res ne 'timeout') {

	    # Assumes SoX-14.1

	    # Default to -9db ( 1 / 2 ^ 3 )
	    my $MAX_VOLUME = 0.6;#0.125;

	    my $max_amplitude = 0;
	    my $record_length = 1;
	    my $file_copy = $tmp_rec_dir.$hash.'-norm.wav';
	    my $stat_cmd = "sox $tmp_record_file_wav_codec $file_copy stat 2>&1";
	    open (STAT, "$stat_cmd |") or die ("Failed: $stat_cmd");
	    while (my $line = <STAT>) {
		#print "line $line\n";
		if ($line =~ /Maximum amplitude:\s+(\d+\.\d+)/) {
		    #print "got line $line\n";
		    $max_amplitude = $1;
		    $self->log (4, "max $max_amplitude");
		}

		if ($line =~ /Length.*?(\d+)\./) {
		    #print "got line $line\n";
		    $record_length = $1;
		    $self->log (4, "length $record_length");
		}

	    }
	    close (STAT);

	    # Assume anything less than two seconds is an error
	    # TODO Does this work for nicknames????
	    my $MIN_RECORD_LENGTH = 2;
	    if ($record_length < $MIN_RECORD_LENGTH) {
		$self->log (4, "recording too short: $record_length");
		$rerecord = 1;
		$silence_loop++;
	    } else {

		# Calculate multiplicator to raise amplitude to -0db
		my $multiplicator = 1 / $max_amplitude;

		$self->log (4, "$tmp_record_file_no_codec: max=$max_amplitude ".
			    "muliplicator=$multiplicator length $record_length");

		my $silence_time = '0:0:0.01';
		my $silence_db = '-55d';

		my $sox_cmd = "sox $tmp_record_file_wav_codec ".
		    "$tmp_record_file_w_codec ".
		    "vol $multiplicator ".
		    "silence $record_length $silence_time $silence_db reverse ".
		    "silence $record_length $silence_time $silence_db reverse ".
		    "vol $MAX_VOLUME";
		$self->log (4, "$sox_cmd");

		# TODO check for errors
		system ($sox_cmd);

	    }

	    unlink $file_copy;
	    unlink $tmp_record_file_wav_codec;


	}

	#$dtmf = $self->agi->stream_file(&msg($self,'beep'),"*",0);

	if ($silence_loop > $MAX_DTMF_PROMPTS) {
	    $res = 'timeout';
	}

	my $rerecord_loop = 0;

	while ($res eq '' && !$rerecord) {


	    $self->log (4, "prompting user to keep $hash");

	    my $input = &get_dtmf_input ($self, $redo_prompt,"123*");

	    if ($input eq 'cancel' || $input eq 'timeout' || $input eq 'hangup') {

		$res = $input;

	    } else {

		$input = chr ($input);

		$self->log (4, "got small number $input");

		# if user keeps pressing 2, just keep playing the file
		while ($input eq '2') {
		    $input = 0;
		    $dtmf = $self->agi->get_option
			($tmp_record_file_no_codec, "123*", 2000);

		    if (defined($dtmf) && $dtmf > 0) {
			$input = chr ($dtmf);
			$self->log (4, "played back file dtmf $dtmf input $input");
		    } else {
			$self->log (4, "played back file dtmf undef");
		    }

		}

		if (!defined($dtmf) || $dtmf < 0) {
		    $res = 'hangup';

		} elsif ($input eq '1') {
		    $res = $tmp_record_file_w_codec;

		} elsif ($input eq '3') {
		    $rerecord = 1;

		} elsif ($input eq '0') {
		    # Do nothing.
		    # This will prompt us again with this same recording.

		} elsif ($input eq '*') {
		    $res = 'cancel';

		} else {
		    die ("Should not be reached dtmf $dtmf input $input");
		}
	    }

	    $rerecord_loop++;
	    if ($res eq '' && $rerecord_loop > $MAX_DTMF_PROMPTS) {
		$res = 'timeout';
	    }

	}

    }

    $self->log (4, "leaving record_file res $res");

    if (($delete_on_hangup && $res eq 'hangup') ||
	$res eq 'timeout' ||
	$res eq 'cancel') {

	&unlink_file ($self, $tmp_record_file_w_codec);
	return $res;
    }

    if (! -e $tmp_record_file_w_codec) {
	# Maybe this can happen if the user hangs up immediately?
	warn ("record_file output file does not exist when it should");
	return 'hangup';
    }

    return $hash;

}

######################################################################
sub unlink_file {
    my ($self, $filename) = @_;
    if (-e $filename) {
	unlink $filename;
	$self->log (4, "unlinked $filename");
    } else {
	$self->log (4, "does not exist to unlink: $filename");
    }
}

######################################################################
sub unlink_tmp_file {
    my ($self, $filename) = @_;
    &unlink_file ($self, "$tmp_rec_dir"."$filename".'.'.&codec());
}


######################################################################

sub mv_tmp_to_comment_dir {
    my ($self, $file) = @_;
    return &mv_tmp_to_dir ($self, $file, $comments_dir, 0);
}

sub mv_tmp_to_post_dir {
    my ($self, $file, $days) = @_;
    return &mv_tmp_to_dir ($self, $file, $posts_dir, $days);
}

sub mv_tmp_to_names_dir {
    my ($self, $file) = @_;
    return &mv_tmp_to_dir ($self, $file, $names_dir, 0);
}

sub mv_tmp_to_status_dir {
    my ($self, $file) = @_;
    return &mv_tmp_to_dir ($self, $file, $status_dir, 0);
}

sub mv_tmp_to_dir {
    my ($self, $file, $dir, $days) = @_;

    my $expiration = &year_month_day_plus_n_days_dir($days);

    my $from = "$tmp_rec_dir"."$file".'.'.&codec();
    my $to = "$dir"."$expiration";
    my $dest = "$expiration"."$file";

    $self->log (4, "moving from $from to $to dest $dest\n");

    if (!move ($from,$to)) {
	$self->log (1, "ERROR moving from $from to $to dest $dest: $!");
	return undef;
    }

    return $dest;
}


######################################################################
#

sub get_pid_filename {
    my ($proc_name) = @_;
    my $PID_DIR='/var/run/asterisk';
    return "$PID_DIR/$proc_name.pid";
}

sub write_pid {
    my ($proc_name) = @_;
    my $pid_filename = &get_pid_filename ($proc_name);
    open PID_FILE, ">$pid_filename" or die ("Cannot write to file $pid_filename");
    print PID_FILE "$$";
    close PID_FILE;
    print STDERR "$proc_name starting with pid $$\n";
}

sub reap_old_self {
    my ($proc_name) = @_;
    my $pid_filename = &get_pid_filename ($proc_name);
    if (-e $pid_filename) {
	open PID_FILE, "$pid_filename" or die ("Cannot read from file $pid_filename");
	my $pid = <PID_FILE>;
	close PID_FILE;
	kill 1, $pid;
	unlink $pid_filename;
	print STDERR "killed old version with pid $$\n";
    }
}



######################################################################
sub place_call {
    my ($call_content) = @_;

    print "START place_call\n\n";

    # TODO change the channel based on the country code
    # Keep in mind that, because we plan to deploy in multiple destinations,
    # the call-out channel needs to be dynamic.

    my $HASH_FILE_LENGTH = 16;
    my $hash = &rnd_alphanum ($HASH_FILE_LENGTH);

    my $callfile = "$tmp_dir"."/place_call/$hash.call";
    $cbCount++;
    open CALL, ">$callfile" or die ("Cannot open $callfile");
    print CALL "$call_content";
    close CALL;

    my $mvcmd = "mv $callfile $calldir";
    system ($mvcmd) == 0 or die ("Failed $mvcmd", $?);

    print "END place_call\n\n";

}


######################################################################

sub stream_file {
    my ($self, $prompts, $digits) = @_;

    my $dtmf = 0;
    if (ref($prompts) eq 'ARRAY') {
	for (my $i = 0; $i <= $#$prompts && $dtmf == 0; $i++) {
	    $dtmf = $self->agi->stream_file
		(&msg($self, $prompts->[$i]), $digits, "0");
	}
    } else {
	$dtmf = $self->agi->stream_file
	    (&msg($self, $prompts), $digits, "0");
    }
    return $dtmf;
}

######################################################################

sub say_number {
    my ($self, $number) = @_;

    die if !defined($self);
    die if !defined($number);

    # plays but gives perl undef error (missing args)
    # $self->agi->say_number(9);

    $self->log (3, "saying number $number");
    my $ret = $self->agi->say_number($number);
    return $ret;
}

######################################################################

sub get_channel_desc {
    my $self = shift;

    my $desc = "channel = ".$self->input('channel');
    $desc .= " context = ".$self->input('context');
    $desc .= " extension = ".$self->input('extension');
    $desc .= " priority = ".$self->input('priority');
    return $desc;
}

######################################################################

sub db_connect {
    my ($self) = @_;

    $self->log (2, "Connecting to database ".$self->get_property('dsn'));
    
    $self->{server}{dbi} = DBI->connect_cached
	($self->get_property('dsn'), 
	 $self->get_property('db_user'), 
	 $self->get_property('db_pw'), 
	 { RaiseError => 1});
    
    if (!defined ($self->{server}{dbi})) {
	die ("Could not connect to database ".$self->get_property('DB_DSN'));
    }
}

######################################################################

sub db_disconnect {
    my $self = shift;
    print STDERR ("Disconnecting from database");

    #print STDERR Dumper ($self);

    if (defined ($self) && defined ($self->{server}) && defined ($self->{server}{dbi})) {
	$self->{server}{dbi}->disconnect;
    }
}


######################################################################
# Record a message to randomly named (new) file
# Return "-1" if error, otherwise name of file

# removed

######################################################################

sub get_hash_file {
    # OK, so contains a very, very unlikely race condition.

    my ($prefix, $suffix, $num_digits) = @_;
    my $exists = 1;
    my $filename = '';
    while ($exists) {
	$filename = &rnd_alphanum ($num_digits);
	my $full_filename = $prefix.$filename.$suffix;
	if (! -e $full_filename) {
	    $exists = 0;
	}
    }
    return $filename;
}

sub rnd_alphanum {
    my ($num_digits) = @_;
    my (@d) = Math::Random::random_uniform_integer($num_digits,0,35);
    my $ret = '';
    for (my $i = 0; $i < $num_digits; $i++) {
	if ($d[$i] <= 9) { $ret .= $d[$i]; next; }
	if ($d[$i] == 10) { $ret .= 'a'; next; }
	if ($d[$i] == 11) { $ret .= 'b'; next; }
	if ($d[$i] == 12) { $ret .= 'c'; next; }
	if ($d[$i] == 13) { $ret .= 'd'; next; }
	if ($d[$i] == 14) { $ret .= 'e'; next; }
	if ($d[$i] == 15) { $ret .= 'f'; next; }
	if ($d[$i] == 16) { $ret .= 'g'; next; }
	if ($d[$i] == 17) { $ret .= 'h'; next; }
	if ($d[$i] == 18) { $ret .= 'i'; next; }
	if ($d[$i] == 19) { $ret .= 'j'; next; }
	if ($d[$i] == 20) { $ret .= 'k'; next; }
	if ($d[$i] == 21) { $ret .= 'l'; next; }
	if ($d[$i] == 22) { $ret .= 'm'; next; }
	if ($d[$i] == 23) { $ret .= 'n'; next; }
	if ($d[$i] == 24) { $ret .= 'o'; next; }
	if ($d[$i] == 25) { $ret .= 'p'; next; }
	if ($d[$i] == 26) { $ret .= 'q'; next; }
	if ($d[$i] == 27) { $ret .= 'r'; next; }
	if ($d[$i] == 28) { $ret .= 's'; next; }
	if ($d[$i] == 29) { $ret .= 't'; next; }
	if ($d[$i] == 30) { $ret .= 'u'; next; }
	if ($d[$i] == 31) { $ret .= 'v'; next; }
	if ($d[$i] == 32) { $ret .= 'w'; next; }
	if ($d[$i] == 33) { $ret .= 'x'; next; }
	if ($d[$i] == 34) { $ret .= 'y'; next; }
	if ($d[$i] == 35) { $ret .= 'z'; next; }
	die ("huh");
    }

    print STDERR "rnd alphanum ret $ret\n";
    return $ret;
}

######################################################################

sub user_has_hungup {
    my ($self) = @_;
    if (!defined($self->agi->channel_status(""))) {
	return 1;
    }

    $self->log (4, "channel status ".$self->agi->channel_status(""));

    return 0;
}

######################################################################
sub init_user {
    my ($self) = @_;

    # Create user if he does not exist, else fill in info about him.

    my %user = (
	id => 0, 
	status => 'good',
	place_id => -1,
	pin => 0,
	callback_limit => 0,
	language_id => 1);

    $self->{user} = \%user;
    $self->{newuser} = 0;

    # sets user->phone, which may be a cleaned up version of callerid
    # also sets carrier
    my $res = &parse_callerid ($self);
    if ($res < 0) {
	return $res;
    }

    while ($self->{user}->{id} == 0) {
	$self->{server}{get_user_sth} = $self->{server}{dbi}->prepare_cached
	("SELECT users.user_id,status,place_id,phone_number phone,user_pin,callback_limit,".
	 "language_id ".
	 "FROM users ".
	 "INNER JOIN user_phones on users.user_id  = user_phones.user_id WHERE phone_number = ?");

	$self->{server}{get_user_sth}->execute
	    ($self->{user}->{phone});

	if ($self->{server}{get_user_sth}->rows > 0) {
	    my $user_info =
		$self->{server}{get_user_sth}->fetchrow_arrayref();
	    $self->{user}->{id} = $user_info->[0];
	    $self->{user}->{status} = $user_info->[1];
	    $self->{user}->{place_id} = $user_info->[2];
	    $self->{user}->{phone} = $user_info->[3];
	    $self->{user}->{pin} = $user_info->[4];
	    $self->{user}->{callback_limit} = $user_info->[5];
	    $self->{user}->{language_id} = $user_info->[6];

	    $self->log (3, "init_user found user ".$self->{user}->{id}.
		      " callerid ".$self->{user}->{phone});

	} else {

	    my %user_desc = ();
	    $user_desc{phone} = $self->{user}->{phone};
	    my $new_user_id = &create_user ($self, \%user_desc);

	    $self->{newuser} = 1;

	}
	$self->{server}{get_user_sth}->finish();
    }

    if ($self->{newuser} == 0) {
	$self->{callcount} = &get_callcount ($self, $self->{user}->{id});
	$self->log (4, "user_id ".$self->{user}->{id}." callcount ".$self->{callcount});
	if ($self->{callcount} == 0) {
	    $self->{newuser} = 1;
	}

    } else {
	$self->{callcount} = 0;

    }

    # TODO select language also
    $self->{language_model} = $ENV{NASI_HOME}."/sr/english.models";
    $self->log (3, "init_user using language model ".$self->{language_model});

    $self->{user}->{language} =
	&get_language_name ($self->{user}->{language_id});
    
    #Set(CHANNEL(language)=hu) 

    return 0;

}

######################################################################
# create_user
# returns id of new user

sub create_user {
    my ($self, $desc) = @_;
    $self->log (3, "start create_user");

    # assume new user is like current user
    # unless other values are passed in
    if (!defined($desc->{place_id})) {
	$desc->{place_id} = $self->{user}->{place_id};
    }	
    if (!defined($desc->{language_id})) {
	$desc->{language_id} = $self->{user}->{language_id};
    }

    $self->log (3, "place_id ".$desc->{place_id}.
	      " phone ".$desc->{phone}.
	      " language_id ".$desc->{language_id});

    $self->{server}{user_insert_sth} =
	$self->{server}{dbi}->prepare_cached
	("INSERT INTO users (place_id, ".
	 "language_id, create_stamp) ".
	 "VALUES ".
	 "(?, ?, NULL)");
    $self->{server}{user_insert_sth}->execute 
	($desc->{place_id},
	 $desc->{language_id});

    my $new_user_id = $self->{server}{user_insert_sth}->{mysql_insertid};

    $self->{server}{user_insert_sth}->finish();
    
    $self->{server}{user_insert_phone_sth} =
        $self->{server}{dbi}->prepare_cached
	("INSERT INTO user_phones (country_id, phone_number, user_id, is_primary) ".
	 "VALUES ".
	 "(1, ?, ?, 'yes');");
    $self->{server}{user_insert_phone_sth}->execute($desc->{phone}, $new_user_id);
    $self->{server}{user_insert_phone_sth}->finish();

    #group mine
    $self->{server}{group_insert_sth} =
	$self->{server}{dbi}->prepare_cached
	("INSERT INTO groups (group_name, group_type, is_active) ".
	 "VALUES (?, 'mine', 'yes')");
    $self->{server}{group_insert_sth}->execute($desc->{phone});
    my $group_id = $self->{server}{group_insert_sth}->{mysql_insertid};
    $self->{server}{group_insert_sth}->finish();
    
    #user group
    $self->{server}{user_group_insert_sth} =
	$self->{server}{dbi}->prepare_cached
	("INSERT INTO user_groups (user_id, group_id, slot, is_quiet) ".
	 "VALUES (?, ?, 1, 'no')");
    $self->{server}{user_group_insert_sth}->execute($new_user_id, $group_id);
    $self->{server}{user_group_insert_sth}->finish();
    
    #user group hist
    my $action = &get_action($self, "joined group");
    $self->{server}{user_group_hist_insert_sth} =
	$self->{server}{dbi}->prepare_cached
	("INSERT INTO user_group_history (group_id, action_id, user_id) ".
	 "VALUES (?, ?, ?)");
    $self->{server}{user_group_hist_insert_sth}->execute 
	($group_id, $action, $new_user_id);
    $self->{server}{user_group_hist_insert_sth}->finish();
    
    #group admin
    $self->{server}{group_admin_insert_sth} =
	$self->{server}{dbi}->prepare_cached
	("INSERT INTO group_admin (user_id, group_id) ".
	 "VALUES (?, ?)");
    $self->{server}{group_admin_insert_sth}->execute 
	($new_user_id, $group_id);
    $self->{server}{group_admin_insert_sth}->finish();
    
    #admin group hist
    $action = &get_action($self, "created group");
    $self->{server}{admin_group_insert_sth} =
	$self->{server}{dbi}->prepare_cached
	("INSERT INTO admin_group_history (group_id, action_id, user_src_id, user_dst_id) ".
	 "VALUES (?, ?, ?, ?)");
    $self->{server}{admin_group_insert_sth}->execute
	($group_id, $action, $new_user_id, $new_user_id);
    $self->{server}{admin_group_insert_sth}->finish();
    
    $self->log (3, "end create_user new_user_id $new_user_id");

    return $new_user_id;
    
}

######################################################################
sub get_action {
    my ($self, $action) = @_;
    
    $self->{server}{get_action_sth} =
	$self->{server}{dbi}->prepare_cached
	("Select action_id from actions WHERE action_desc = ?");
    $self->{server}{get_action_sth}->execute($action);
    my $action_id = $self->{server}{get_action_sth}->fetchrow_arrayref()->[0];
    $self->{server}{get_action_sth}->finish();
    
    $self->log(4, "Action: desc=$action, id=$action_id");
    
    return $action_id;
}

######################################################################
sub get_callcount {
    my ($self, $user_id) = @_;

    $self->{server}{get_callcount_sth} =
	$self->{server}{dbi}->prepare_cached
	("SELECT count(*) as callcount from calls where user_id=?");

    $self->{server}{get_callcount_sth}->execute
	($user_id);

    my ($callcount) = 
	$self->{server}{get_callcount_sth}->fetchrow_array();
    $self->{server}{get_callcount_sth}->finish();

    return $callcount;

}

######################################################################
#
sub get_user_id {
    my ($self, $phone) = @_;
    $self->{server}{get_user_id_sth} =
	$self->{server}{dbi}->prepare_cached
	("SELECT user_id FROM users WHERE phone = ?");

    $self->{server}{get_user_id_sth}->execute ($phone);

    my $user_id = 0;
    if ($self->{server}{get_user_id_sth}->rows > 0) {
	$user_id = $self->{server}{get_user_id_sth}->fetchrow_arrayref()->[0];
    }
    $self->{server}{get_user_id_sth}->finish();
    return $user_id;
}

######################################################################
#
sub get_user_name {
    my ($self, $user_id) = @_;

    $self->log (4, "get_users_name start user_id $user_id");

    $self->{server}{get_users_name_sth} =
	$self->{server}{dbi}->prepare_cached
	("SELECT name_file FROM users WHERE user_id = ?");

    $self->{server}{get_users_name_sth}->execute ($user_id);
    my $name_file = $self->{server}{get_users_name_sth}->fetchrow_arrayref()->[0];
    $self->{server}{get_users_name_sth}->finish ();

    if (!defined($name_file)) {
	$self->log (4, "get_users_name end user_id $user_id name_file null");
	return undef;
    }

    $name_file = $names_dir.$name_file;
    $self->log (4, "get_users_name end user_id $user_id name_file $name_file");
    return $name_file;
}

######################################################################
#
sub set_user_name {
    my ($self, $user_id, $prompt) = @_;

    my $name_file = &record_file
	($self, $prompt, 6, &msg($self, 'to-keep-your-nickname'));
    if ($name_file eq 'timeout') { return 'timeout'; }

    $name_file = &mv_tmp_to_names_dir ($self, $name_file);
    $self->{server}{set_users_name_sth} =
	$self->{server}{dbi}->prepare_cached
	("UPDATE users SET name_file = ? WHERE user_id = ?");
    $self->{server}{set_users_name_sth}->execute ($name_file, $user_id);
    $self->{server}{set_users_name_sth}->finish ();

    return $name_file;

}


######################################################################

sub get_seconds_remaining_count {
    my ($self) = @_;

    # When calculating this, ignore very short entries in the call table.

    $self->log (3, "get_seconds_remaining_count id ".$self->{user}->{id});

    # TODO make per-person
    #my $MAX_CALLBACKS_PER_DAY = 1000;
    #print STDERR "max callback is $MAX_CALLBACKS_PER_DAY\n";

    #$self->{server}{states_sth} =
    #$self->{server}{dbi}->prepare_cached
    #("select state from incoming where callerid = ? AND stamp > DATE_SUB(NOW(),INTERVAL 24 HOUR)");
    #$self->{server}{states_sth}->execute ($callerid);
    
    #print STDERR "got row states ".$self->{server}{states_sth}->rows."\n";

    #my $calledbackCount = 0;

    #if ($self->{server}{states_sth}->rows > 0) {
    #my $states = $self->{server}{states_sth}->fetchall_arrayref({ state => 1});
    #my $callCount = 0;

    #foreach my $state (@$states) {
    #if ($self->{state} eq 'calledback') {
    #$calledbackCount++;
    #}
    #}
    #}
    #$self->{server}{states_sth}->finish();

    #return $MAX_CALLBACKS_PER_DAY - $calledbackCount;

    return 120;

}



######################################################################

sub check_end_network_modify_menu {
  my ($self, $state, $action) = @_;

  if ($state eq 'timeout' || $state eq 'cancel' ||
      $state eq 'hangup') {

    if ($state eq 'timeout' || $state eq 'cancel') {
      &play_random ($self, &msg($self,"cancelled-$action"), 'ok');
    }
    $self->log (4, "a $action s $state");
    return 1;
  }
  return 0;
}

######################################################################
sub get_network_of_friendship {
    my ($self,$dst_user_id,$src_user_id) = @_;

    if (!defined($src_user_id)) {
	$src_user_id = $self->{user}->{id};
    }

    $self->{server}{get_network_of_friendship_sth} =
	    $self->{server}{dbi}->prepare_cached
	    ("SELECT channel from friends where src_user_id=?".
	     " AND dst_user_id=?");
    $self->{server}{get_network_of_friendship_sth}->execute
	($src_user_id, $dst_user_id);

    my $channel = undef;
    if ($self->{server}{get_network_of_friendship_sth}->rows > 0) {
	$channel = 
	    $self->{server}{get_network_of_friendship_sth}->fetchrow_arrayref()->[0];
    }
    $self->{server}{get_network_of_friendship_sth}->finish();
    return $channel;
}

######################################################################
# XXX This function should not be in here

sub select_network_menu {
    my ($self,$prompt,$can_select_all) = @_;

    $self->log (4, "start select_network_menu");

    my $digits = "0123456789";
    if ($can_select_all == 1) {
		$digits = "0123456789";
    }

    my $network_code = &get_unchecked_small_number
	($self, $prompt, $digits);

    $self->log (4, "received network_code $network_code");

    if ($network_code eq 'timeout' ||
		$network_code eq 'hangup' ||
		$network_code eq 'cancel') {
			return $network_code;
    }

    $self->log (4, "end select_network_menu");

    #return the group_id based on the selected slot
    $self->{server}{get_group_sth} =
	$self->{server}{dbi}->prepare_cached
	("SELECT group_id FROM user_groups ".
	 "WHERE user_id = ? AND slot = ?");
    $self->log (4, "SELECT group_id FROM user_groups ".
		"WHERE user_id = $self->{user}->{id} AND slot = $network_code");
    $self->{server}{get_group_sth}->execute($self->{user}->{id}, $network_code);
    my $group = $self->{server}{get_group_sth}->fetchrow_arrayref();
    
    $self->{server}{get_group_sth}->finish();
    
    return (defined($group)) ? $group = $group->[0] : $group;
    
	
    die ("Should not be reached");

}

######################################################################
sub set_nickname_file {
  my ($self, $src_user_id, $dst_user_id, $filename) = @_;



  # mv file from tmp to right dir
  $filename = &mv_tmp_to_dir ($self, $filename, $nicknames_dir, 0);

  if (defined (&get_nickname_file ($self, $src_user_id, $dst_user_id))) {
    # update

    $self->{server}{update_nickname_file_sth} =
      $self->{server}{dbi}->prepare_cached
	("UPDATE nicknames SET filename = ? , text = NULL ".
	 "WHERE src_user_id = ? AND dst_user_id = ?");
    $self->{server}{update_nickname_file_sth}->execute
      ($filename, $src_user_id, $dst_user_id);
    $self->{server}{update_nickname_file_sth}->finish();


  } else {
    # insert

    $self->{server}{insert_nickname_file_sth} =
      $self->{server}{dbi}->prepare_cached
	("INSERT INTO nicknames (src_user_id, dst_user_id, filename) ".
	 " VALUES (?, ?, ?)");
    $self->{server}{insert_nickname_file_sth}->execute
      ($src_user_id, $dst_user_id, $filename);
    $self->{server}{insert_nickname_file_sth}->finish();

  }

  # clear the cache
  my $nickname_pair = 'nickname-'.$src_user_id.'-'.$dst_user_id;
  $self->{$nickname_pair} = undef;

  return $filename;

}

######################################################################
# Deprecated
sub get_nickname_file {
  my ($self, $src_user_id, $dst_user_id) = @_;

  $self->log (4, "src $src_user_id dst $dst_user_id");

  # cache nicknames for future reference
  my $nickname_pair = 'nickname-'.$src_user_id.'-'.$dst_user_id;

  if (!defined($self->{$nickname_pair})) {

      $self->{server}{get_nickname_file_sth} =
	  $self->{server}{dbi}->prepare_cached
	  ("SELECT filename from nicknames where src_user_id=?".
	   " AND dst_user_id=?");
      $self->{server}{get_nickname_file_sth}->execute
	  ($src_user_id, $dst_user_id);

      my $nickname_file = undef;
      if ($self->{server}{get_nickname_file_sth}->rows > 0) {
	  $nickname_file = 
	      $self->{server}{get_nickname_file_sth}->fetchrow_arrayref()->[0];
	  # resolve to full path
	  $nickname_file = $nicknames_dir.$nickname_file;
      }
      $self->{server}{get_nickname_file_sth}->finish();

      $self->{$nickname_pair} = $nickname_file;

  }

  return $self->{$nickname_pair};
}

######################################################################
# client side of SMS daemon
# send SMS to SMS queuing daemon and return immediately

sub sms_enqueue {
    my ($self, $phone, $msg) = @_;

    if (!defined($phone)) {
	$self->log (3, "not enqueuing sms with no phone");
	return;
    }

    if (!defined($msg)) {
	$self->log (3, "not enqueuing sms with no msg");
	return;
    }

    my $socket = IO::Socket::INET->new(PeerAddr => '127.0.0.1',
				       PeerPort => 9275,
				       Proto => "tcp",
				       Type => SOCK_STREAM)
	or die "Could not connect to sms daemon";
    print $socket "$phone $msg";
    close ($socket);
}


1;