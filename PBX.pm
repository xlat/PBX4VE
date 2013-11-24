package PBX;
use strict;
use warnings;
use Win32::API;
use File::Slurp qw(write_file);
use Encode qw( decode );

our $VERSION = 0.1;

#convert a wchar_t* from utf-16le to what perl want.
sub decode_LPCWSTR {
   my ($ptr) = @_;
   return undef unless $ptr;
   my $sW = '';
   while(42){
      my $chW = unpack('P2', pack('L', $ptr));
      last if $chW eq "\0\0";
      $sW .= $chW;
      $ptr += 2;
   }
   return decode('UTF-16le', $sW);   
}


#no comment
sub new{
	my ($class, $pbx) = @_;
	return bless{ pbx => $pbx }, $class;
}

#extract PBX description
sub get_description{
	my $self = shift;
	my $api = Win32::API->new( $self->{pbx}, 'DWORD _PBX_GetDescription@0( )');
	my $desc = decode_LPCWSTR( $api->Call );
	undef $api;
	return $desc;
}

#parse PBX description en generate *.SRU and *.SRF output files
sub export{
	my $self=shift;
	my $desc = $self->get_description;
	#Export objects
	while( $desc =~ /\bclass\s+(\w+)\s+from\s+(\w+)(.*?)\bend\s+class\b/gs ){ 
		my ($class, $ancestor, $prototypes) = ($1, $2, $3);
		if(($prototypes||'')=~/^\s*$/s){
			print "\tskipped empty definition for $class inherited from $ancestor\n";
			next
		}
		my (@events, @methods, @eventsdec, @methodsdec);
		foreach my $proto( grep { !/^\s*$/ } split /\r?\n/, $prototypes ){
			if(my @items = ( $proto=~/^\s*event\s*(?:(\w+)\s+(\w+)\(([^)]*)\)(\s+throws\s+.*)?|(\w+)\s+(\w+))\s*$/ ) ){
				my ($type, $name, $id, $throws, $args) = ( $items[0]||'', $items[1]||$items[4], $items[5]||'', $items[3]||'', $items[2] );
				if($type){
					$throws ||= '';
					push @events, "event type $type $name ( $args ) $throws";
					push @eventsdec, "event type $type $name ( $args );\n$type $type\nreturn $type\nend event";
				}
				else{
					push @events, "event $name $id";
					push @eventsdec, "event $name;\nreturn\nend event";
				}
			}
			elsif($proto =~ /^\s*(subroutine|function)(?:\s+(\w+))?\s+(\w+)\(([^)]*)\)(?:\s+(throws .*))?\s*$/){
				my ($kind, $type, $name, $args, $throws) = ($1, $2 || '', $3, $4, $5 || '');
				push @methods, "$kind $type $name($args) $throws";
				push @methodsdec, "$kind $type $name($args) $throws;\n$type $type\nreturn $type\nend $kind";
			}
		}
		my $events = join $/, @events;
		my $methods = join $/, @methods;
		my $eventsdec = join $/, @eventsdec;
		my $methodsdec = join $/, @methodsdec;
		
		my $source = <<USEROBJECT;
\$PBExportHeader\$${class}.sru
forward
global type $class from $ancestor
end type
end forward

global type $class from $ancestor
$events
end type
global $class $class

forward prototypes
$methods
end prototypes

$eventsdec

$methodsdec

on $class.create
call super::create
TriggerEvent( this, "constructor" )
end on

on $class.destroy
TriggerEvent( this, "destructor" )
call super::destroy
end on
USEROBJECT
		
		print "\texport ${class}.sru (inherited from $ancestor)\n";
		write_file( "${class}.sru", $source ) or warn "argh: $!\n";
	}
	
	#Export global functions
	if($desc =~ /\bglobalfunctions\b(.*?)end\s+globalfunctions\b/s){
		my $descgf = $1;
		while( $descgf =~ /^\s*(subroutine|function)(?:\s+(\w+))?\s+(\w+)\(([^)]*)\)(?:\s+(throws .*))?\s*$/mg ){ 
			my ($kind, $type, $name, $args, $throws) = ($1, $2, $3, $4, $5);
			my $code = $type ? "$type $type\nreturn $type" : 'return';
			$throws ||= '';
			my $source = <<FUNCTION;
\$PBExportHeader\$${name}.srf
global type $name from function_object
end type

forward prototypes
global $kind $type $name ($args) $throws
end prototypes

global $kind $type $name ($args) $throws;$code
end $kind
FUNCTION
			print "\texport ${name}.srf\n";
			write_file( "${name}.srf", $source ) or warn "argh: $!\n";
		}
	}
}

#perl mechanism to handle module arguments
sub import{
	shift;
	foreach my $f(@_){
		foreach(glob $f){
			print $_,$/;
			PBX->new($_)->export;
		}
	}
	exit if @_;
}
1;