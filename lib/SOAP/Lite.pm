# ======================================================================
#
# Copyright (C) 2000-2001 Paul Kulchenko (paulclinger@yahoo.com)
# SOAP::Lite is free software; you can redistribute it
# and/or modify it under the same terms as Perl itself.
#                      
# $Id: SOAP::Lite.pm,v 0.50 2001/04/18 11:45:14 $
#
# ======================================================================

package SOAP::Lite;

use 5.004;
use strict;
use vars qw($VERSION);
$VERSION = '0.50';

# ======================================================================

package SOAP::Constants;

use vars qw($NSMASK $ELMASK);

$NSMASK = '[a-zA-Z_:][\w.\-:]*'; 
$ELMASK = '^(?![xX][mM][lL])[a-zA-Z_][\w.\-]*$';

use vars qw($NEXT_ACTOR $NS_XSD $NS_XSI $NS_ENV $NS_ENC $NS_APS
            $FAULT_CLIENT $FAULT_SERVER $FAULT_VERSION_MISMATCH
            $HTTP_ON_FAULT_CODE $HTTP_ON_SUCCESS_CODE $FAULT_MUST_UNDERSTAND
            $CNS $SLP $SLN
            $PREFIX_ENV $PREFIX_ENC
            $DO_NOT_USE_XML_PARSER $DO_NOT_CHECK_MUSTUNDERSTAND $DO_NOT_USE_CHARSET
);

$FAULT_CLIENT = 'Client';
$FAULT_SERVER = 'Server';
$FAULT_VERSION_MISMATCH = 'VersionMismatch';
$FAULT_MUST_UNDERSTAND = 'MustUnderstand';

$HTTP_ON_SUCCESS_CODE = 200; # OK
$HTTP_ON_FAULT_CODE   = 500; # INTERNAL_SERVER_ERROR

$NEXT_ACTOR = 'http://schemas.xmlsoap.org/soap/actor/next';

# schema namespaces                                    
$NS_XSD = 'http://www.w3.org/1999/XMLSchema';          
$NS_XSI = 'http://www.w3.org/1999/XMLSchema-instance'; 

# soap namespaces
$NS_ENV = 'http://schemas.xmlsoap.org/soap/envelope/';
$NS_ENC = 'http://schemas.xmlsoap.org/soap/encoding/';

# default prefixes
$PREFIX_ENV = 'SOAP-ENV';
$PREFIX_ENC = 'SOAP-ENC';

# ApacheSOAP namespaces
$NS_APS = 'http://xml.apache.org/xml-soap';

# SOAP::Lite prefix
$SLP = 'SOAP-Lite';
$SLN = 'http://www.soaplite.com/';

# internal mark for current namespace
$CNS = 'xmlns:-';

# others
$DO_NOT_USE_XML_PARSER = 0;
$DO_NOT_CHECK_MUSTUNDERSTAND = 0;
$DO_NOT_USE_CHARSET = 0;

# ======================================================================

package SOAP::Utils;

sub qualify { $_[1] ? $_[1] =~ /:/ ? $_[1] : join(':', $_[0] ? ($_[0], $_[1]) : ($_[1])) : '' }
sub overqualify (&$) { for ($_[1]) { &{$_[0]}; s/^:|:$//g } }
sub disqualify {
  (my $qname = shift) =~ s/^($SOAP::Constants::NSMASK)://;
  $qname;
}

# ======================================================================

package SOAP::Cloneable;

sub clone {
  my $self = shift;
  return unless ref $self && UNIVERSAL::isa($self => __PACKAGE__);
  my $clone = bless {} => ref($self) || $self;
  foreach (keys %$self) {
    my $value = $self->{$_};
    $clone->{$_} = ref $value && UNIVERSAL::isa($value => __PACKAGE__) ? $value->clone : $value;
  }
  $clone;
}

# ======================================================================

package SOAP::Transport;

use vars qw($AUTOLOAD @ISA);

@ISA = qw(SOAP::Cloneable);

sub DESTROY { SOAP::Trace::objects('()') }

sub new { 
  my $self = shift;
  my $class = ref($self) || $self;
  return $self if ref $self;

  SOAP::Trace::objects('()');
  return bless {} => $class;
}

sub proxy {
  my $self = shift->new;
  my $class = ref $self;

  return $self->{_proxy} unless @_;
  $_[0] =~ /^(\w+):/ or die "proxy: transport protocol not specified\n";
  my $protocol = uc $1; # untainted now
  # https: should be done through Transport::HTTP.pm
  for ($protocol) { s/^HTTPS$/HTTP/ }

  (my $protocol_class = "${class}::$protocol") =~ s/-/_/g;
  no strict 'refs';
  unless (defined %{"$protocol_class\::Client::"} && UNIVERSAL::can("$protocol_class\::Client" => 'new')) {
    eval "require $protocol_class";
    die "Unsupported protocol '$protocol'\n" if $@ =~ /^Can't locate/;
    die if $@;
  }
  $protocol_class .= "::Client";
  return $self->{_proxy} = $protocol_class->new(endpoint => shift, @_);
}

sub AUTOLOAD {
  my $method = substr($AUTOLOAD, rindex($AUTOLOAD, '::') + 2);
  return if $method eq 'DESTROY';

  no strict 'refs';
  *$AUTOLOAD = sub { shift->proxy->$method(@_) };
  goto &$AUTOLOAD;
}

# ======================================================================

package SOAP::Fault;

use Carp ();

sub DESTROY { SOAP::Trace::objects('()') }

sub new { 
  my $self = shift;

  unless (ref $self) {
    my $class = ref($self) || $self;
    $self = bless {} => $class;
    SOAP::Trace::objects('()');
  }

  Carp::carp "Odd (wrong?) number of parameters in new()" if $^W && (@_ & 1); 
  while (@_) { my $method = shift; $self->$method(shift) if $self->can($method) }

  return $self;
}

sub BEGIN {
  no strict 'refs';
  for my $method (qw(faultcode faultstring faultactor faultdetail)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = UNIVERSAL::isa($_[0] => __PACKAGE__) ? shift->new : __PACKAGE__->new;
      if (@_) { $self->{$field} = shift; return $self }
      return $self->{$field};
    }
  }
  *detail = \&faultdetail;
}

# ======================================================================

package SOAP::Data;

use vars qw(@ISA @EXPORT_OK);
use Exporter;
use Carp ();

@ISA = qw(Exporter);
@EXPORT_OK = qw(name type attr value uri);

sub DESTROY { SOAP::Trace::objects('()') }

sub new { 
  my $self = shift;

  unless (ref $self) {
    my $class = ref($self) || $self;
    $self = bless {_attr => {}, _value => [], _signature => []} => $class;
    SOAP::Trace::objects('()');
  }

  Carp::carp "Odd (wrong?) number of parameters in new()" if $^W && (@_ & 1); 
  while (@_) { my $method = shift; $self->$method(shift) if $self->can($method) }

  return $self;
}

sub BEGIN {
  no strict 'refs';
  for my $method (qw(name attr)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = UNIVERSAL::isa($_[0] => __PACKAGE__) ? shift->new : __PACKAGE__->new;
      if (@_) { $self->{$field} = shift; $self->value(@_) if @_; return $self }
      return $self->{$field};
    }
  }
  for my $method (qw(type)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = UNIVERSAL::isa($_[0] => __PACKAGE__) ? shift->new : __PACKAGE__->new;
      if (@_) { $self->{$field} = shift; $self->value(@_) if @_; return $self }
      ($self->{$field}) = map {$self->{_attr}->{$_}} grep {/^xsi:$method$/o} keys %{$self->{_attr}}
        unless defined $self->{$field};
      return $self->{$field};
    }
  }
  for my $method (qw(root mustUnderstand)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = UNIVERSAL::isa($_[0] => __PACKAGE__) ? shift->new : __PACKAGE__->new;
      if (@_) {
        $self->{$field} = shift() ? 1 : 0; 
        $self->{_attr}->{"${SOAP::Constants::PREFIX_ENV}:$method"} = $self->{$field}; 
        $self->value(@_) if @_; 
        return $self
      }
      $self->{$field} = SOAP::Deserializer->as_boolean(map {$self->{_attr}->{$_}} grep {/(^|:)$method$/o} keys %{$self->{_attr}})
        unless defined $self->{$field}; 
      return $self->{$field};
    }
  }
  for my $method (qw(actor encodingStyle)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = UNIVERSAL::isa($_[0] => __PACKAGE__) ? shift->new : __PACKAGE__->new;
      if (@_) {
        $self->{$field} = shift();
        $self->{_attr}->{"${SOAP::Constants::PREFIX_ENV}:$method"} = $self->{$field};
        $self->value(@_) if @_;
        return $self;
      }
      ($self->{$field}) = map {$self->{_attr}->{$_}} grep {/(^|:)$method$/o} keys %{$self->{_attr}}
        unless defined $self->{$field};
      return $self->{$field};
    }
  }
}

sub uri {
  my $self = UNIVERSAL::isa($_[0] => __PACKAGE__) ? shift->new : __PACKAGE__->new;
  return $self->{_uri} unless @_;
  my $uri = $self->{_uri} = $self->{_attr}->{'xmlns:~'} = shift; 
  warn "Usage of '::' in URI ($uri) is deprecated. Use '/' instead\n"
    if defined $uri && $^W && $uri =~ /::/;
  $self->value(@_) if @_;
  return $self;
}

sub set_value {
  my $self = UNIVERSAL::isa($_[0] => __PACKAGE__) ? shift->new : __PACKAGE__->new;
  $self->{_value} = [@_];
  return $self; 
}

sub value {
  my $self = UNIVERSAL::isa($_[0] => __PACKAGE__) ? shift->new : __PACKAGE__->new;
  @_ ? ($self->set_value(@_), return $self) 
     : wantarray ? return @{$self->{_value}} : return $self->{_value}->[0];
}

sub signature {
  my $self = UNIVERSAL::isa($_[0] => __PACKAGE__) ? shift->new : __PACKAGE__->new;
  @_ ? ($self->{_signature} = shift, return $self) : (return $self->{_signature});
}

# ======================================================================

package SOAP::Header;

use vars qw(@ISA);
@ISA = qw(SOAP::Data);

# ======================================================================

package SOAP::Serializer;

use Carp ();
use vars qw(@ISA);

@ISA = qw(SOAP::Cloneable);

BEGIN {
  # namespaces and anonymous data structures
  my $ns   = 0; 
  my $name = 0; 
  my $prefix = 'c-';
  sub gen_ns { 'namesp' . ++$ns } 
  sub gen_name { join '', $prefix, 'gensym', ++$name } 
  sub prefix { $prefix =~ s/^[^\-]+-/$_[1]-/; $_[0]; }
  sub encode_data { (my $e = $_[0]) =~ s/([&<])/$1 eq '&'?'&amp;':'&lt;'/eg; $e }
  sub encode_attribute { (my $e = $_[0]) =~ s/([&<"])/$1 eq '&'?'&amp;':$1 eq '<'?'&lt;':'&quot;'/eg; $e }
}

sub DESTROY { SOAP::Trace::objects('()') }

sub new { 
  my $self = shift;

  unless (ref $self) {
    my $class = ref($self) || $self;
    $self = bless {
      _indent => 0,
      _autotype => 1,
      _readable => 0,
      _multirefinplace => 0,
      _attr => {
        'xmlns:xsd' => $SOAP::Constants::NS_XSD,
        'xmlns:xsi' => $SOAP::Constants::NS_XSI,
        $SOAP::Constants::PREFIX_ENC ? (qualify(xmlns => $SOAP::Constants::PREFIX_ENC) => $SOAP::Constants::NS_ENC) : (),
        $SOAP::Constants::PREFIX_ENV ? (qualify(xmlns => $SOAP::Constants::PREFIX_ENV) => $SOAP::Constants::NS_ENV) : (),
        $SOAP::Constants::PREFIX_ENV ? (qualify($SOAP::Constants::PREFIX_ENV => 'encodingStyle') => $SOAP::Constants::NS_ENC) : (),
      },
      _seen => {},
      _typelookup => {
        base64 => [10, sub {$_[0] =~ /[^\x09\x0a\x0d\x20-\x7f]/}, 'as_base64'],
        int    => [20, sub {$_[0] =~ /^[+-]?\d+$/}, 'as_int'],
        float  => [30, sub {$_[0] =~ /^(-?(?:\d+(?:\.\d*)?|\.\d+|NaN|INF)|([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?)$/}, 'as_float'],
        string => [40, sub {1}, 'as_string'],
      },
      _namespace => $SOAP::Constants::PREFIX_ENV,
      _encodingspace => $SOAP::Constants::PREFIX_ENC,
      _encoding => 'UTF-8',
      _objectstack => {},
      _signature => [],
      _maptype => {SOAPStruct => $SOAP::Constants::NS_APS},
      _on_nonserialized => sub {Carp::carp "Cannot marshall @{[ref shift]} reference" if $^W; return},
    } => $class;
    SOAP::Trace::objects('()');
  }

  Carp::carp "Odd (wrong?) number of parameters in new()" if $^W && (@_ & 1); 
  while (@_) { my $method = shift; $self->$method(shift) if $self->can($method) }

  return $self;
}

sub BEGIN {
  no strict 'refs';
  for my $method (qw(readable indent seen autotype typelookup uri attr maptype
                     namespace encodingspace multirefinplace encoding signature
                     on_nonserialized)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = shift->new;
      @_ ? ($self->{$field} = shift, return $self) : return $self->{$field};
    }
  }
  for my $method (qw(method fault freeform)) { # aliases for envelope
    *$method = sub { shift->envelope($method => @_) }
  }
  for my $method (qw(qualify overqualify disqualify)) { # import from SOAP::Utils
    *$method = \&{'SOAP::Utils::'.$method};
  }
}

sub gen_id { 0+$_[1] }

sub multiref_object {
  my $self = shift;
  my $object = shift;
  my $id = $self->gen_id($object);
  my $seen = $self->seen;
  $seen->{$id}->{count}++;
  $seen->{$id}->{multiref} ||= $seen->{$id}->{count} > 1;
  $seen->{$id}->{value} = $object;
  $seen->{$id}->{recursive} ||= 0;
  return $id;
}

sub recursive_object { 
  my $self = shift; 
  $self->seen->{$self->gen_id(shift)}->{recursive} = 1;
}

sub is_href { 
  my $self = shift;
  my $seen = $self->seen->{shift || return} or return;
  return 1 if $seen->{id};
  return $seen->{multiref} &&
         !($seen->{id} = (shift || 
                          $seen->{recursive} || 
                          $seen->{multiref} && $self->multirefinplace));
}

sub multiref_anchor { 
  my $seen = shift->seen->{my $id = shift || return undef};
  return $seen->{multiref} ? "ref-$id" : undef;
}

sub encode_multirefs {
  my $self = shift;
  return if $self->multirefinplace;

  my $seen = $self->seen;
  map { $_->[1]->{_id} = 1; $_ 
      } map { $self->encode_object($seen->{$_}->{value}) 
            } grep { $seen->{$_}->{multiref} && !$seen->{$_}->{recursive}
                   } keys %$seen;
}

# ----------------------------------------------------------------------

sub maptypetouri {
  my ($self, $type) = @_;

  if (defined $type && $type !~ /:/) {
    (my $fixed = $type) =~ s/__/::/g;
    $self->maptype->{$fixed} = $self->uri || return $type
      unless exists $self->maptype->{$fixed};
    if ($self->maptype->{$fixed}) {
      my %attr = reverse %{$self->attr};
      my $uri = $self->maptype->{$fixed};
      my($prefix) = exists $attr{$uri} ? $attr{$uri} =~ /^xmlns:(.+)/
        : do { my $prefix = gen_ns; $self->attr->{"xmlns:$prefix"} = $uri; $prefix };
      $type = qualify($prefix => $type);
    } else {
      $type = undef;
    }
  }
  return $type;
}

sub encode_object {
  my($self, $object, $name, $type, $attr) = @_;

  $attr ||= {};

  return $self->encode_scalar($object, $name, $type, $attr) unless ref $object;

  my $id = $self->multiref_object($object); 

  use vars '%objectstack';           # we'll play with symbol table 
  local %objectstack = %objectstack; # want to see objects ONLY in the current tree
  # did we see this object in current tree? Seems to be recursive refs
  $self->recursive_object($object) if ++$objectstack{$id} > 1;
  # return if we already saw it twice. It should be already properly serialized
  return if $objectstack{$id} > 2;

  if (UNIVERSAL::isa($object => 'SOAP::Data')) { 
    # using $object->SOAP::Data:: to enable overriding name() and others in inherited classes
    $object->SOAP::Data::name($name) unless defined $object->SOAP::Data::name;
    my @realvalues = $object->SOAP::Data::value;
    my $attr = $object->SOAP::Data::attr;
    return [$object->SOAP::Data::name || gen_name, $attr] unless @realvalues;

    my $method = 'as_' . ($object->SOAP::Data::type || '-'); # dummy type if not defined
    # try to call method specified for this type
    my @values = map { 
         $self->can($method) && $self->$method($_, $object->SOAP::Data::name || gen_name, $object->SOAP::Data::type, {(defined() ? () : ('xsi:null' => 1)), %$attr})
      || $self->typecast($_, $object->SOAP::Data::name || gen_name, $object->SOAP::Data::type, $attr)
      || $self->encode_object($_, $object->SOAP::Data::name, $object->SOAP::Data::type, $attr)
    } @realvalues;
    $object->SOAP::Data::signature([map {join $;, $_->[0], $_->[1]->{'xsi:type'} || ''} @values]) if @values;
    return wantarray ? @values : $values[0];
  } 

  my $class = ref $object;
  if ($class !~ /^(?:SCALAR|ARRAY|HASH|REF)$/o) { 
    # we could also check for CODE|GLOB|LVALUE, but we cannot serialize 
    # them anyway, so they'll be catched by check below
    $class =~ s/::/__/g;

    $name = $class if !defined $name;
    $type = $class if !defined $type && $self->autotype;

    my $method = 'as_' . $class;
    if ($self->can($method)) {
      my $encoded = $self->$method($object, $name, $type, $attr);
      return $encoded if ref $encoded;
      # return only if handled, otherwise handle with default handlers
    }
  }

  return 
    UNIVERSAL::isa($object => 'REF') ||
    UNIVERSAL::isa($object => 'SCALAR') ? $self->encode_scalar($object, $name, $type, $attr) :
    UNIVERSAL::isa($object => 'ARRAY')  ? $self->encode_array($object, $name, $type, $attr) :
    UNIVERSAL::isa($object => 'HASH')   ? $self->encode_hash($object, $name, $type, $attr) :
                                          $self->on_nonserialized->($object); 
}

sub encode_scalar {
  my($self, $value, $name, $type, $attr) = @_;
  $name ||= gen_name;

  # null reference
  return [$name, {%$attr, 'xsi:null' => 1}] unless defined $value;

  # object reference
  return [$name, $attr, [$self->encode_object($$value)], $self->gen_id($value)] if ref $value;

  # defined type
  return [$name, {%$attr, 'xsi:type' => qualify('xsd' => $self->maptypetouri($type))}, $value] if defined $type;

  # autodefined type 
  if ($self->autotype) {
    my $lookup = $self->typelookup;
    for (sort {$lookup->{$a}->[0] <=> $lookup->{$b}->[0]} keys %$lookup) {
      my $typecast = $lookup->{$_}->[2];
      $lookup->{$_}->[1]->($value) and return $self->can($typecast) 
        ? $self->$typecast($value, $name, $type, $attr) 
# TD: add check for CODE reference. Die on error
        : $typecast->($value, $name, $type, $attr);
    }
  }

  # invariant
  return [$name, $attr, $value];
}

sub encode_array {
  my($self, $array, $name, $type, $attr) = @_;
  my $items = 'item'; 

# TD: add support for multidimensional, partially transmitted and sparse arrays
  my @items = map {$self->encode_object($_, $items)} @$array;
  my $num = @items;
  my($arraytype, %types) = '-';
  for (@items) { $arraytype = $_->[1]->{'xsi:type'} || '-'; $types{$arraytype}++ }
  $arraytype = sprintf "%s\[$num]", keys %types > 1 || $arraytype eq '-' ? 'xsd:ur-type' : $arraytype;

  $type = 'Array' if $self->autotype && !defined $type; # make ApacheSOAP users happy
  return [$name || qualify($self->encodingspace => 'Array'), 
          {qualify($self->encodingspace => 'arrayType') => $arraytype, 'xsi:type' => qualify($self->encodingspace => $type), %$attr},
          [@items], $self->gen_id($array)
  ];
}

sub encode_hash {
  my($self, $hash, $name, $type, $attr) = @_;

  if ($self->autotype && grep {!/$SOAP::Constants::ELMASK/o} keys %$hash) {
    warn qq!Cannot encode @{[$name ? "'$name'" : 'unnamed']} element as 'hash'. Will be encoded as 'map' instead\n! if $^W;
    return $self->as_map($hash, $name || gen_name, $type, $attr);
  }

  $type = 'SOAPStruct' if $self->autotype && !defined $type && exists $self->maptype->{SOAPStruct}; # make ApacheSOAP users happy
  return [$name || gen_name, 
          {'xsi:type' => qualify($self->encodingspace => $self->maptypetouri($type)), %$attr}, 
          [map {$self->encode_object($hash->{$_}, $_)} keys %$hash], 
          $self->gen_id($hash)
  ];
}

# ----------------------------------------------------------------------

sub as_base64 {
  my $self = shift;
  my($value, $name, $type, $attr) = @_;
  require MIME::Base64;
  return [$name, {'xsi:type' => qualify($self->encodingspace => 'base64'), %$attr}, MIME::Base64::encode_base64($value,'')];
}

sub as_hex { 
  my $self = shift;
  my($value, $name, $type, $attr) = @_;
  return [$name, {'xsi:type' => 'xsd:hex', %$attr}, join '', map {sprintf "%x", ord} split '', $value];
}

sub as_int {
  my $self = shift;
  my($value, $name, $type, $attr) = @_;
  die "Integer value expected instead of @{[ref $value]} reference\n" if ref $value;
  return [$name, {'xsi:type' => 'xsd:int', %$attr}, $value];
}

sub as_float {
  my $self = shift;
  my($value, $name, $type, $attr) = @_;
  die "Float value expected instead of @{[ref $value]} reference\n" if ref $value;
  return [$name, {'xsi:type' => 'xsd:float', %$attr}, $value];
}

sub as_string {
  my $self = shift;
  my($value, $name, $type, $attr) = @_;
  die "String value expected instead of @{[ref $value]} reference\n" if ref $value;
  return [$name, {'xsi:type' => 'xsd:string', %$attr}, encode_data($value)];
}

sub as_boolean {
  my $self = shift;
  my($value, $name, $type, $attr) = @_;
  return [$name, {'xsi:type' => 'xsd:boolean', %$attr}, $value ? 'true' : 'false'];
}

sub as_ordered_hash {
  my $self = shift;
  my($value, $name, $type, $attr) = @_;
  die "Not an ARRAY reference for 'ordered_hash' type" unless UNIVERSAL::isa($value => 'ARRAY');
  return [$name, $attr, 
    [map{$self->encode_object(@{$value}[2*$_+1,2*$_])} 0..$#$value/2], 
    $self->gen_id($value)
  ];
}

sub as_map {
  my $self = shift;
  my($value, $name, $type, $attr) = @_;
  die "Not a HASH reference for 'map' type" unless UNIVERSAL::isa($value => 'HASH');
  $self->attr->{'xmlns:xmlsoap'} = $SOAP::Constants::NS_APS;
  my @items = map {$self->encode_object(SOAP::Data->type(ordered_hash => [key => $_, value => $value->{$_}]), 'item', '')} keys %$value;
  return [$name, {'xsi:type' => 'xmlsoap:Map', %$attr}, [@items], $self->gen_id($value)];
}

sub as_xml {
  my $self = shift;
  my($value, $name, $type, $attr) = @_;
  return [$name, {'_xml' => 1}, $value];
}

sub typecast {
  my $self = shift;
  my($value, $name, $type, $attr) = @_;
  return if ref $value; # skip complex object, caller knows how to do with it
  return if $self->autotype && !defined $type; # we don't know, autotype knows
  return [$name,
          {(defined $type && $type gt '' ? ('xsi:type' => qualify('xsd' => $self->maptypetouri($type))) : ()), %$attr},
          $value
  ];
}

# ----------------------------------------------------------------------

sub tag {
  my $self = shift;
  my($tag, $attrs, @values) = @_;
  my $value = join '', @values;
  my $indent = $self->readable ? "\n" . ' ' x $self->indent : '';
  # check for special attribute
  return "$indent$value" if exists $attrs->{_xml} && delete $attrs->{_xml}; 
  die "Element '$tag' can't be allowed in valid XML message. Died\n"
    if $tag !~ /^(?![xX][mM][lL])$SOAP::Constants::NSMASK$/o;
  my $preserve = exists $attrs->{_preserve} && delete $attrs->{_preserve};
  my $tagattrs = join(' ', '', map { sprintf '%s="%s"', $_, encode_attribute($attrs->{$_}) } 
                              grep { $_ && defined $attrs->{$_} && ($_ ne 'xsi:type' || $attrs->{$_} ne '')
                                   } keys %$attrs);
  $value gt '' 
    ? sprintf("$indent<%s%s$indent>%s</%s>", $tag, $tagattrs, $value, $tag) 
    : $preserve || $tagattrs ? sprintf("$indent<%s%s/>", $tag, $tagattrs) : '';
}

sub xmlize {
  my $self = shift;
  my($name, $attrs, $values, $id) = @{+shift}; $attrs ||= {};

  delete $attrs->{$SOAP::Constants::CNS}; # drop internal attribute

  if (exists $attrs->{'xmlns:~'} && defined(my $xmlns = delete $attrs->{'xmlns:~'})) {
    my $ns = ($name =~ s/^($SOAP::Constants::NSMASK):// ? $1 : gen_ns);
    # xmlns:a='' is incorrect, will be xmlns=''
    if ($xmlns ne '') {
      $attrs->{"xmlns:$ns"} = $xmlns; 
      $name = "$ns:$name";
    } else {
      $attrs->{'xmlns'} = $xmlns; 
    }
  }

  # commented on 04/15/2001 for better interoperability
  # seems like nobody understands this style anyway
  # local $self->{_multirefinplace} = 1 if $name =~ /(^|:)Header$/;
  local $self->{_current_namespace} = $1 if $name =~ /^($SOAP::Constants::NSMASK):/;

  $name =~ s/^~(?=:)/$self->{_current_namespace}/;

  local $self->{_indent} = $self->{_indent} + 2;
  return $self->tag($name, $attrs) unless defined $values;
  return $self->tag($name, $attrs, $values) unless UNIVERSAL::isa($values => 'ARRAY');
  return $self->tag($name, {%$attrs, href => '#' . $self->multiref_anchor($id)}) if $self->is_href($id, delete($attrs->{_id}));
  return $self->tag($name, {%$attrs, id => $self->multiref_anchor($id)}, map {$self->xmlize($_)} @$values);
}

sub uriformethod {
  my $self = shift;

  my $method_is_data = ref $_[0] && UNIVERSAL::isa($_[0] => 'SOAP::Data');

  # drop prefrix from method that could be string or SOAP::Data object
  my $prefix = (my $method = $method_is_data ? $_[0]->name : $_[0]) =~ s/^($SOAP::Constants::NSMASK)://
    ? $1 : '';

  my $attr = $self->attr || {};
  # try to define namespace that could be stored as
  #   a) method is SOAP::Data 
  #        ? attribute in method's element as xmlns= or xmlns:${prefix}=
  #        : uri
  #   b) attribute in Envelope element as xmlns= or xmlns:${prefix}=
  #   c) no prefix or prefix equal serializer->namespace
  #        ? '', but see coment below
  #        : die with error message
  my $uri = $method_is_data 
    ? ref $_[0]->attr && ($_[0]->attr->{$prefix ? "xmlns:$prefix" : 'xmlns'} || $_[0]->attr->{'xmlns:~'})
    : $self->uri;

  defined $uri or $uri = $attr->{$prefix ? "xmlns:$prefix" : 'xmlns'};

  defined $uri or $uri = !$prefix || $prefix eq $self->namespace 
    # still in doubts what should namespace be in this case 
    # but will keep it like this for now and be compatible with our server
    ? ( $method_is_data && $^W && warn("URI is not provided as an attribute for method ($method)\n"),
        ''
      )
    : die "Can't find namespace for method ($prefix:$method)\n";

  return ($uri, $method);
}

sub serialize { SOAP::Trace::trace('()');
  my $self = shift->new;
  $self->seen({}); # reinitialize multiref table
  my @encoded = map { $self->encode_object($_) } @_;
  return join '', map { $self->xmlize($_) } 
           @encoded, $self->encode_multirefs;
}

sub envelope { SOAP::Trace::trace('()');
  my $self = shift->new;
  my $type = shift;

  my(@parameters, @header);
  for (@_) { 
    defined $_ && ref $_ && UNIVERSAL::isa($_ => 'SOAP::Header') 
      ? push(@header, $_) : push(@parameters, $_);
  }
  my $header = SOAP::Data->set_value(@header);
  my($body,$parameters);
  if ($type eq 'method') {
    SOAP::Trace::method(@parameters);
    my $method = shift(@parameters) or die "Unspecified method for SOAP call\n";
    $parameters = SOAP::Data->set_value(@parameters);
    $body = UNIVERSAL::isa($method => 'SOAP::Data') 
      ? $method->value(\$parameters)
      : SOAP::Data->name($method => \$parameters)->uri($self->uri);
    $body->attr->{_preserve} = 1; # always preserve method element
  } elsif ($type eq 'fault') {
    SOAP::Trace::fault(@parameters);
    $body = SOAP::Data
      -> name(qualify($self->namespace => 'Fault'))
    # commented on 2001/03/28 because of failing in ApacheSOAP
    # need to find out more about it
    # -> attr({'xmlns' => ''})
      -> value(\SOAP::Data->set_value(
        SOAP::Data->name(faultcode => qualify($self->namespace => $parameters[0])),
        SOAP::Data->name(faultstring => $parameters[1]),
        defined($parameters[2]) ? SOAP::Data->name(detail => do{my $detail = $parameters[2]; ref $detail ? \$detail : $detail}) : (),
        defined($parameters[3]) ? SOAP::Data->name(faultactor => $parameters[3]) : (),
      ));
  } elsif ($type eq 'freeform') {
    SOAP::Trace::freeform(@parameters);
    $body = SOAP::Data->set_value(@parameters);
  } else {
    die "Wrong type of envelope ($type) for SOAP call\n";
  }

  $self->seen({}); # reinitialize multiref table
  my($encoded) = $self->encode_object(
    SOAP::Data->name(qualify($self->namespace => 'Envelope') => \SOAP::Data->value(
      SOAP::Data->name(qualify($self->namespace => 'Header') => \$header),
      SOAP::Data->name(qualify($self->namespace => 'Body')   => \$body)
    ))->attr($self->attr)
  );
  $self->signature($parameters->signature) if ref $parameters;

  # IMHO multirefs should be encoded after Body, but only some
  # toolkits understand this encoding, so we'll keep them for now (04/15/2001)
  # as the last element inside the Body 
  push(@{$encoded->[2]->[1]->[2]}, $self->encode_multirefs);
  return join '', qq!<?xml version="1.0" encoding="@{[$self->encoding]}"?>!,
                  $self->xmlize($encoded);
}

# ======================================================================

package SOAP::Parser;

sub DESTROY { SOAP::Trace::objects('()') }

sub xmlparser {
  my $self = shift;
  return eval { $SOAP::Constants::DO_NOT_USE_XML_PARSER ? undef : do {require XML::Parser; XML::Parser->new} } || 
         eval { require XML::Parser::Lite; XML::Parser::Lite->new } ||
         die "XML::Parser is not @{[$SOAP::Constants::DO_NOT_USE_XML_PARSER ? 'used' : 'available']} and ", $@;
}

sub parser {
  my $self = shift->new;
  @_ ? ($self->{'_parser'} = shift, return $self) : return $self->{'_parser'};
}

sub new { 
  my $self = shift;
  my $class = ref($self) || $self;

  return $self if ref $self;

  SOAP::Trace::objects('()');
  $self = bless {} => $class;
  $self->{_parser} = shift || $self->xmlparser;
  $self->{_parser}->setHandlers(
    Init  => sub { shift; $self->init(@_) },
    Final => sub { shift; $self->final(@_) },
    Start => sub { shift; $self->start(@_) },
    End   => sub { shift; $self->end(@_)   },
    Char  => sub { shift; $self->char(@_)  }, 
  );
  return $self;
}

sub decode { SOAP::Trace::trace('()');
  my $self = shift; 

  $self->parser->parse($_[0]);
}

sub init { undef shift->{_values} }

sub final { shift->{_done} }

sub start { push @{shift->{_values}}, [shift, {@_}] }

sub char { shift->{_values}->[-1]->[3] .= shift }

sub end { 
  my $self = shift; 
  my $done = pop @{$self->{_values}};
  undef $done->[3] if ref $done->[2];
  @{$self->{_values}} ? (push @{$self->{_values}->[-1]->[2]}, $done)
                      : ($self->{_done} = $done);
}

# ======================================================================

package SOAP::MIMEParser;

use vars qw(@ISA);

@ISA = qw(MIME::Parser);

sub DESTROY { SOAP::Trace::objects('()') }

sub new { local $^W; require MIME::Parser; Exporter::require_version('MIME::Parser' => 5.220); 
  my $self = shift;

  unless (ref $self) {
    my $class = ref($self) || $self;
    $self = $class->SUPER::new();
    unshift(@_, output_to_core => 'ALL', tmp_to_core => 1, ignore_errors => 1);
    SOAP::Trace::objects('()');
  }

  while (@_) { my $method = shift; $self->$method(shift) if $self->can($method) }

  return $self;
}

sub get_multipart_id { (shift || '') =~ /^<(.+)>$/; $1 || '' }

sub decode { 
  my $self = shift;

  my $entity = eval { $self->parse_data(shift) } or die "Something wrong with MIME message: @{[$@ || $self->last_error]}\n";

  my @result = 
    $entity->head->mime_type eq 'multipart/form-data' ? $self->decode_form_data($entity) :
    $entity->head->mime_type eq 'multipart/related' ? $self->decode_related($entity) :
    $entity->head->mime_type eq 'text/xml' ? () :
    die "Can't handle MIME messsage with specified type (@{[$entity->head->mime_type]})\n";

  @result ? @result 
          : $entity->bodyhandle->as_string ? [undef, '', undef, $entity->bodyhandle->as_string]
                                           : die "No content in MIME message\n";
}

sub decode_form_data { 
  my($self, $entity) = @_;

  my @result;
  foreach my $part ($entity->parts) {
    my $name = $part->head->mime_attr('content-disposition.name');
    my $type = $part->head->mime_type || '';

    $name eq 'payload' 
      ? unshift(@result, [$name, '', $type, $part->bodyhandle->as_string])
      : push(@result, [$name, '', $type, $part->bodyhandle->as_string]);
  }
  @result;
}

sub decode_related { 
  my($self, $entity) = @_;
  my $start = get_multipart_id($entity->head->mime_attr('content-type.start'));
  my $location = $entity->head->mime_attr('content-location') || 'thismessage:/';

  my @result;
  foreach my $part ($entity->parts) {
    my $pid = get_multipart_id($part->head->get('content-id',0));
    my $plocation = $part->head->get('content-location',0) || '';
    my $type = $part->head->mime_type || '';

    $start && $pid eq $start 
      ? unshift(@result, [$start, $location, $type, $part->bodyhandle->as_string])
      : push(@result, [$pid, $plocation, $type, $part->bodyhandle->as_string]);
  }
  die "Can't find 'start' parameter in multipart MIME message\n"
    if @result > 1 && !$start;
  @result;
}

# ======================================================================

package SOAP::SOM;

use Carp ();

sub BEGIN {
  no strict 'refs';
  my %path = (
    root        => '/',
    envelope    => '/Envelope',
    body        => '/Envelope/Body',
    header      => '/Envelope/Header',
    headers     => '/Envelope/Header/[>0]',
    fault       => '/Envelope/Body/Fault',
    faultcode   => '/Envelope/Body/Fault/faultcode',
    faultstring => '/Envelope/Body/Fault/faultstring',
    faultactor  => '/Envelope/Body/Fault/faultactor',
    faultdetail => '/Envelope/Body/Fault/detail',
  );
  for my $method (keys %path) {
    *$method = sub { 
      my $self = shift;
      ref $self or return $path{$method};
      Carp::croak "Method '$method' is readonly and doesn't accept any parameters" if @_;
      return $self->valueof($path{$method});
    };
  }
  my %results = (
    method    => '/Envelope/Body/[1]',
    result    => '/Envelope/Body/[1]/[1]',
    paramsin  => '/Envelope/Body/[1]/[>0]',
    paramsall => '/Envelope/Body/[1]/[>0]',
    paramsout => '/Envelope/Body/[1]/[>1]',
  );
  for my $method (keys %results) {
    *$method = sub { 
      my $self = shift;
      ref $self or return $results{$method};
      Carp::croak "Method '$method' is readonly and doesn't accept any parameters" if @_;
      defined $self->fault ? return : return $self->valueof($results{$method});
    };
  }
}

# use object in boolean context return true/false on last match
# Ex.: $som->match('//Fault') ? 'SOAP call failed' : 'success';
use overload fallback => 1, 'bool'  => sub { @{shift->{_current}} > 0 };

sub DESTROY { SOAP::Trace::objects('()') }

sub new { 
  my $self = shift;
  my $class = ref($self) || $self;
  my $content = shift;
  SOAP::Trace::objects('()');
  return bless { _content => $content, _current => [$content] } => $class;
}

sub valueof {
  my $self = shift;
  local $self->{_current} = $self->{_current}; 
  $self->match(shift) if @_;
  return wantarray ? map {$_->[4]} @{$self->{_current}} 
                   : @{$self->{_current}} ? $self->{_current}->[0]->[4] : undef;
}

sub headerof { # SOAP::Header is the same as SOAP::Data, so just rebless it
  wantarray 
    ? map { bless $_ => 'SOAP::Header' } shift->dataof(@_) 
    : bless shift->dataof(@_) => 'SOAP::Header';
}

sub dataof {
  my $self = shift;
  local $self->{_current} = $self->{_current}; 
  $self->match(shift) if @_;
  return wantarray ? map {$self->_as_data($_)} @{$self->{_current}} 
                   : @{$self->{_current}} ? $self->_as_data($self->{_current}->[0]) : undef;
}

sub namespaceuriof {
  my $self = shift;
  local $self->{_current} = $self->{_current}; 
  $self->match(shift) if @_;
  return wantarray ? map {$_->[1]->{$SOAP::Constants::CNS}} @{$self->{_current}} 
                   : @{$self->{_current}} ? $self->{_current}->[0]->[1]->{$SOAP::Constants::CNS} : undef;
}

sub _as_data {
  my $self = shift;
  my $pointer = shift;
  SOAP::Data
    -> new(name => $pointer->[0], attr => $pointer->[1])
    -> set_value($pointer->[4]);
}

sub match { 
  my $self = shift;
  my $path = shift;
  $self->{_current} = [
    $path =~ s!^/!! || !@{$self->{_current}}
      ? $self->_traverse($self->{_content}, 1 => split '/' => $path)
      : map {$self->_traverse_tree($_->[2], split '/' => $path)} @{$self->{_current}}
  ];
  return $self;
}

sub _traverse {
  my $self = shift;
  my($pointer, $itself, $path, @path) = @_;
  my($op, $num) = $path =~ /^\[(<=|<|>=|>|=|!=?)?(\d+)\]$/ if defined $path;

  return $pointer unless defined $path;

  $op = '==' unless $op; $op .= '=' if $op eq '=' || $op eq '!';
  my $numok = defined $num && eval "$itself $op $num";
  my $nameok = ($pointer->[0] || '') =~ /(?:^|:)$path$/ if defined $path; # name can be with namespace

  my $anynode = $path eq '';
  unless ($anynode) {
    if (@path) {
      return if defined $num && !$numok || !defined $num && !$nameok;
    } else {
      return $pointer if defined $num && $numok || !defined $num && $nameok;
      return;
    }
  }

  my @walk;
  push @walk, $self->_traverse_tree([$pointer], @path) if $anynode;
  push @walk, $self->_traverse_tree($pointer->[2], $anynode ? ($path, @path) : @path);
  return @walk;
}

sub _traverse_tree {
  my $self = shift;
  my($pointer, @path) = @_;
  my $itself = 1;
  grep {defined} map {$self->_traverse($_, $itself++, @path)} @$pointer;
}

# ======================================================================

package SOAP::Deserializer;

use vars qw(@ISA);

@ISA = qw(SOAP::Cloneable);

sub DESTROY { SOAP::Trace::objects('()') }

sub BEGIN {
  no strict 'refs';
  for my $method (qw(ids hrefs parser base)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = shift->new;
      @_ ? ($self->{$field} = shift, return $self) : return $self->{$field};
    }
  }
}

sub new { 
  my $self = shift;
  my $class = ref($self) || $self;
  return $self if ref $self;

  SOAP::Trace::objects('()');
  return bless {
    _ids => {}, 
    _hrefs => {},
    _parser => SOAP::Parser->new,
  } => $class;
}

sub mimeparser {
  my $field = '_mimeparser';
  my $self = shift->new;
  @_ ? ($self->{$field} = shift, return $self) 
     : return $self->{$field} ||= new SOAP::MIMEParser;
}

sub is_xml {
  $_[1] =~ /^\s*</ || $_[1] !~ /^[\w-]+:/;
}

sub baselocation { 
  my $self = shift;
  my $location = shift;
  if ($location) { 
    my $uri = URI->new($location); 
    # make absolute location if relative
    $location = $uri->abs($self->base)->as_string unless $uri->scheme;
  }
  $location;
}

sub mimedecode {
  my $self = shift->new;

  my $body;
  foreach ($self->mimeparser->decode($_[0])) {
    my($id, $location, $type, $value) = @$_;

    unless ($body) { # we are here for the first time, so it's a MAIN part
      $body = $self->parser->decode($value);
      $self->base($location); # store the base location
    } else {
      $location = $self->baselocation($location);
      my $part = $type eq 'text/xml' ? $self->parser->decode($value) : ['', undef, undef, $value];
      $self->ids->{$id} = $part if $id;
      $self->ids->{$location} = $part if $location;
    }
  }
  return $body;
}

sub decode {
  my $self = shift->new;
  return $self->is_xml($_[0]) 
    ? $self->parser->decode($_[0]) 
    : $self->mimedecode($_[0]);
}

sub deserialize { SOAP::Trace::trace('()');
  my $self = shift->new;

  $self->ids({})->hrefs({}); # initialize 

  # TBD: find better way to signal parsing errors
  my $parsed = $self->decode($_[0]); # TBD: die on possible errors in Parser?
  $self->traverse_ids($parsed);
  $self->decode_object($parsed);
  return SOAP::SOM->new($parsed);
}

sub traverse_ids {
  my $self = shift;
  my $ref = shift;
  my($undef, $attrs, $childs) = @$ref;
  #  ^^^^^^ to fix nasty error on Mac platform (Carl K. Cunningham)

  $self->ids->{$attrs->{id}} = $ref if exists $attrs->{id};
  return unless ref $childs;
  for (@$childs) {$self->traverse_ids($_)};
}

sub decode_object {
  my $self = shift;              
  my $ref = shift;
  my($name, $attrs, $childs, $value) = @$ref;

  use vars qw($ns %uris); # drop namespace from name
  local %uris = (%uris, map {$_ => $attrs->{$_}} grep {/^xmlns(:|$)/} keys %$attrs);

  # first check the attributes
  foreach (keys %$attrs) {
    do { $1 =~ /^[xX][mX][lL]/ ||
         $uris{"xmlns:$1"} || 
         die "Unresolved prefix '$1' for attribute '$_'\n" },
    do { $2 ne 'encodingStyle' ||
         length($attrs->{$_}) == 0 || # encodingStyle=""
         $attrs->{$_} =~ /\b$SOAP::Constants::NS_ENC/ ||
         die "Unrecognized/unsupported value of encodingStyle attribute\n" }
      if m/^($SOAP::Constants::NSMASK):($SOAP::Constants::NSMASK)/;
  }

  # and now check the element
  local $ns = ($name =~ s/^($SOAP::Constants::NSMASK):// ? $1 : '');
  $ref->[1]->{$SOAP::Constants::CNS} = 
    $ns ? ($uris{"xmlns:$ns"} || die "Unresolved prefix '$ns' for element '$name'\n")
        : ($uris{"xmlns"}     || undef); # that's ok

  return $name => undef if grep {/:null$/ && $self->as_boolean($attrs->{$_})} keys %$attrs;
  return $name => ($ref->[4] = $self->decode_value($ref));
}

sub decode_value {
  my $self = shift;
  my $ref = shift;
  my($name, $attrs, $childs, $value) = @$ref;

  my($type) = map {$attrs->{$_}} grep {/^xsi:type$/} keys %$attrs;
  my @classes = map {s/^$SOAP::Constants::NSMASK://; $_} 
                grep {defined} $type, $name;
  no strict 'refs'; 
  my($class) = grep { s/__/::/g; $_ } @classes;
  my $method = 'as_' . ($type || '-'); # dummy type if not defined

  my $id = $attrs->{id};

  if (defined $id && exists $self->hrefs->{$id}) {
    return $self->hrefs->{$id};
  } elsif (exists $attrs->{href}) {
    (my $id = delete $attrs->{href}) =~ s/^(#|cid:)?//;
    # convert to absolute if not internal '#' or 'cid:'
    $id = $self->baselocation($id) unless $1;
    if (exists $self->hrefs->{$id}) {
      return $self->hrefs->{$id};
    } elsif (exists $self->ids->{$id}) {
      my $obj = $self->decode_value(delete $self->ids->{$id});
      return $self->hrefs->{$id} = $obj; 
    } else {
      die "Unresolved (wrong?) href ($id) in element '$name'\n";
    }
  }

  # try to handle with typecasting
  my $res = $self->typecast($value, $name, $attrs, $childs, $type);
  return $res if defined $res;

  # ok, continue with others
  if ($name =~ /(?:^|:)Array$/ || grep {/:arrayType$/} keys %$attrs) {
    my $res = []; 
    $self->hrefs->{$id} = $res if defined $id;
    @$res = map {($self->decode_object($_))[1]} @{$childs || []};
    return defined $class && $class ne 'Array' ? bless($res => $class) : $res;
  } elsif ($name =~ /(?:^|:)Struct$/ || !$self->can($method) && (ref $childs || defined $class && !defined $value)) { 
    my $res = {};
    $self->hrefs->{$id} = $res if defined $id;
    %$res = map {$self->decode_object($_)} @{$childs || []};
    return defined $class && $class ne 'SOAPStruct' ? bless($res => $class) : $res;
  } else {
    my $res = $self->can($method) 
      ? $self->$method($value, $name, $attrs, $childs, $type)
      : $self->typecast($value, $name, $attrs, $childs, $type) 
        || ($type ? die "Unrecognized type '$type'\n" : $value);
    $self->hrefs->{$id} = $res if defined $id;
    return $res;
  }
}

# ----------------------------------------------------------------------

sub as_boolean { shift; my $value = shift; $value eq 'true' || $value eq 1 ? 1 : 0 }

sub as_base64 { shift; require MIME::Base64; MIME::Base64::decode_base64(shift) }
sub as_base64Binary; *as_base64Binary = \&as_base64;

sub as_hex { shift; my $value = shift; $value =~ s/([a-zA-Z0-9]{2})/chr oct '0x'.$1/ge; $value }
sub as_hexBinary; *as_hexBinary = \&as_hex;

sub as_map { 
  my $self = shift;
  +{ map { my $hash = $self->decode_value($_); ($hash->{key} => $hash->{value}) } @{$_[3] || []} };
}
sub as_Map; *as_Map = \&as_map;

sub typecast { } # typecast is called for both objects AND scalar types
                 # check ref of the second parameter (first is the object)
                 # return undef if you don't want to handle it

sub as_string { defined $_[1] ? $_[1] : ''; }

BEGIN {
  no strict 'refs';
  for my $method (qw(
float double decimal timeInstant timePeriod month year century 
recurringDate recurringDay timeDuration recurringDuration uriReference
language integer nonPositiveInteger negativeInteger long int short byte
nonNegativeInteger unsignedLong unsignedInt unsignedShort unsignedByte
positiveInteger date time dateTime
  )) { my $name = 'as_' . $method; *$name = sub { $_[1] } }
}

# ======================================================================

package SOAP::Client;

sub BEGIN {
  no strict 'refs';
  for my $method (qw(endpoint code message is_success status options)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = shift->new;
      @_ ? ($self->{$field} = shift, return $self) : return $self->{$field};
    }
  }
}

# ======================================================================

package SOAP::Server::Object;

sub gen_id; *gen_id = \&SOAP::Serializer::gen_id;

my %alive;
my %objects;

sub objects_by_reference { 
  shift; 
  while (@_) { @alive{shift()} = ref $_[0] ? shift : sub { $_[1]-$_[$_[5] ? 5 : 4] > 600 } } 
  keys %alive;
}

sub reference {
  my $self = shift;
  my $stamp = time;
  my $object = shift; 
  my $id = $stamp . $self->gen_id($object);

  # this is code for garbage collection
  my $time = time;
  my $type = ref $object;
  my @objects = grep { $objects{$_}->[1] eq $type } keys %objects;
  for (grep { $alive{$type}->(scalar @objects, $time, @{$objects{$_}}) } @objects) { 
    delete $objects{$_}; 
  } 

  $objects{$id} = [$object, $type, $stamp];
  bless { id => $id } => ref $object;
}

sub references {
  my $self = shift;
  return @_ unless %alive; # small optimization
  map { ref($_) && exists $alive{ref $_} ? $self->reference($_) : $_ } @_;
}

sub object {
  my $self = shift;
  my $class = ref($self) || $self;
  my $object = shift;
  return $object unless ref($object) && $alive{ref $object} && exists $object->{id};
  my $reference = $objects{$object->{id}};
  die "Object with specified id couldn't be found\n" unless ref $reference->[0];
  $reference->[3] = time; # last access time
  return $reference->[0]; # reference to actual object
}

sub objects {
  my $self = shift; 
  return @_ unless %alive; # small optimization
  map { ref($_) && exists $alive{ref $_} && exists $_->{id} ? $self->object($_) : $_ } @_;
}

# ======================================================================

package SOAP::Server::Parameters;

# ======================================================================

package SOAP::Server;

use Carp ();

sub DESTROY { SOAP::Trace::objects('()') }

sub new { 
  my $self = shift;

  unless (ref $self) {
    my $class = ref($self) || $self;
    my(@params, @methods);
    while (@_) { 
      $class->can($_[0]) ? push(@methods, shift() => shift) 
                         : $^W && Carp::carp "Unrecognized parameter '@{[shift, '=>', shift]}' in new()" 
    }
    $self = bless {
      _serializer => SOAP::Serializer->new,
      _deserializer => SOAP::Deserializer->new,
      _dispatch_to => [], 
      _dispatch_with => {}, 
      _dispatched => [],
      _on_action => sub {},
      _action => '',
      _options => {},
    } => $class;
    while (@methods) { my($method, $params) = splice(@methods,0,2);
      $self->$method(ref $params eq 'ARRAY' ? @$params : $params) 
    }
    SOAP::Trace::objects('()');
  }

  Carp::carp "Odd (wrong?) number of parameters in new()" if $^W && (@_ & 1); 
  while (@_) { my($method, $params) = splice(@_,0,2);
    $self->can($method) 
      ? $self->$method(ref $params eq 'ARRAY' ? @$params : $params)
      : $^W && Carp::carp "Unrecognized parameter '$method' in new()"
  }

  return $self;
}

sub BEGIN {
  no strict 'refs';
  for my $method (qw(on_action action myuri serializer deserializer options dispatch_with)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = shift->new;
      @_ ? ($self->{$field} = shift, return $self) : return $self->{$field};
    }
  }
  for my $method (qw(dispatch_to)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = shift->new;
      @_ ? ($self->{$field} = [@_], return $self) 
         : return @{$self->{$field}};
    }
  }
}

sub objects_by_reference { 
  my $self = shift->new;
  @_ ? (SOAP::Server::Object->objects_by_reference(@_), return $self) 
     : SOAP::Server::Object->objects_by_reference; 
}

sub dispatched {
  my $self = shift->new;
  @_ ? (push(@{$self->{_dispatched}}, @_), return $self) 
     : return @{$self->{_dispatched}};
}

sub find_target {
  my $self = shift;
  my $request = shift;

  my($method_uri, $method_name) = ($request->namespaceuriof || '', $request->dataof->name);
  $method_name =~ s/^$SOAP::Constants::NSMASK://; # ignore namespace

  $self->on_action->($self->action, $method_uri, $method_name);

  my($class, $static);
  # try to bind directly
  if (defined($class = $self->dispatch_with->{$method_uri} 
                    || $self->dispatch_with->{$self->action})) {
    # return object, nothing else to do here
    return ($class, $method_uri, $method_name) if ref $class;
    $static = 1;
  } else {
    die "URI path shall map to class" unless defined ($class = URI->new($method_uri)->path);

    for ($class) { s!^/|/$!!g; s!/!::!g; s/^$/main/; } 
    die "Failed to access class ($class)" unless $class =~ /^(\w[\w:]*)$/;

    my $fullname = "$class\::$method_name";
    foreach ($self->dispatch_to) {
      return ($_, $method_uri, $method_name) if ref eq $class; # $OBJECT
      next if ref;                                   # skip other objects
      # will ignore errors, because it may complain on 
      # d:\foo\bar, which is PATH and not regexp
      eval {
        $static ||= 
          $class =~ /^$_$/ ||                          # MODULE
          $fullname =~ /^$_$/ ||                       # MODULE::method
          $method_name =~ /^$_$/ && ($class eq 'main') # method ('main' assumed)
        ;
      };
    }
  }

  no strict 'refs';
  unless (defined %{"${class}::"}) {   
    # allow all for static and only specified path for dynamic bindings
    local @INC = (($static ? @INC : ()), grep {!ref && m![/\\.]!} $self->dispatch_to);
    eval 'local $^W; ' . "require $class";
    die "Failed to access class ($class): $@" if $@;
    $self->dispatched($class) unless $static;
  } 

  die "Denied access to method ($method_name) in class ($class)"  
    unless $static || grep {/^$class$/} $self->dispatched;

  return ($class, $method_uri, $method_name);
}

sub handle { SOAP::Trace::trace('()'); 
  my $self = shift;

  my $result = eval { local $SIG{__DIE__}; 

  my $request = eval { $self->deserializer->deserialize($_[0]) };
  die "Application failed during request deserialization: $@" if $@;

  my $som = ref $request;

  die "Can't find root element in the message" unless $request->match($som->envelope);

  # check for proper namespace, but allow unqualified root element
  die SOAP::Fault->faultcode($SOAP::Constants::FAULT_VERSION_MISMATCH)
                 ->faultstring("Bad Version. Expected '$SOAP::Constants::NS_ENV'")
    if ($request->namespaceuriof || '') ne $SOAP::Constants::NS_ENV &&
        $request->dataof->name =~ /:/o;

  die SOAP::Fault->faultcode($SOAP::Constants::FAULT_MUST_UNDERSTAND)
                 ->faultstring("Header has mustUnderstand attribute set to 'true'")
    if !$SOAP::Constants::DO_NOT_CHECK_MUSTUNDERSTAND &&
       grep { $_->mustUnderstand && (!$_->actor || $_->actor eq $SOAP::Constants::NEXT_ACTOR)
            } $request->dataof($som->headers);

  die "Can't find method element in the message" unless $request->match($som->method);

  my($class, $method_uri, $method_name) = $self->find_target($request);

  my @results = eval { local $^W;
    my @parameters = $request->paramsin;

    # SOAP::Trace::dispatch($fullname);
    SOAP::Trace::parameters(@parameters);

    push @parameters, $request if UNIVERSAL::isa($class => 'SOAP::Server::Parameters');
    SOAP::Server::Object->references(
      defined $parameters[0] && ref $parameters[0] && UNIVERSAL::isa($parameters[0] => $class) 
       ? do { 
           my $object = shift @parameters;
           SOAP::Server::Object->object(ref $class ? $class : $object)->$method_name(
             SOAP::Server::Object->objects(@parameters)), 
           map { $_->name(SOAP::Utils::qualify($SOAP::Constants::SLP => $_->name))
                   ->uri($SOAP::Constants::SLN)
               } $request->headerof($som->method.'/[1]')->value($object)
         }
       : $class->$method_name(SOAP::Server::Object->objects(@parameters))
    );
  };

  SOAP::Trace::result(@results);

  # let application errors pass through with 'Server' code
  die ref $@ ? 
        $@ : $@ =~ /^Can't locate object method "$method_name"/ ? 
        "Failed to locate method ($method_name) in class ($class)" : 
        SOAP::Fault->faultcode($SOAP::Constants::FAULT_SERVER)->faultstring($@)
    if $@;

  return $self->serializer
    -> prefix('s') # distinguish generated element names between client and server
    -> uri($method_uri) 
    -> envelope(method => $method_name . 'Response', @results);
  };

  # void context
  return unless defined wantarray;

  # normal result
  return $result unless $@;

  # check fails, something wrong with message
  return $self->make_fault($SOAP::Constants::FAULT_CLIENT, $@) unless ref $@;

  # died with SOAP::Fault
  return $self->make_fault($@->faultcode   || $SOAP::Constants::FAULT_SERVER, 
                           $@->faultstring || 'Application error',
                           $@->faultdetail, $@->faultactor)
    if UNIVERSAL::isa($@ => 'SOAP::Fault');

  # died with complex detail
  return $self->make_fault($SOAP::Constants::FAULT_SERVER, 'Application error' => $@);
}

sub make_fault { 
  my $self = shift; 
  my($code, $string, $detail, $actor) = @_;
  $self->serializer->fault($code, $string, $detail, $actor || $self->myuri);
} 

# ======================================================================

package SOAP::Trace;

use Carp ();

my @list = qw(transport dispatch result parameters headers objects method fault freeform trace debug);
{ no strict 'refs'; for (@list) { *$_ = sub {} } }

sub defaultlog { 
  my $caller = (caller(1))[3];
  $caller = (caller(2))[3] if $caller =~ /eval/;
  chomp(my $msg = join ' ', @_); 
  printf STDERR "%s: %s\n", $caller, $msg;
} 

sub import { no strict 'refs'; local $^W;
  my $pack = shift;
  my(@notrace, @symbols);
  for (@_) {
    if (ref eq 'CODE') {
      my $call = $_;
      foreach (@symbols) { *$_ = sub { $call->(@_) } }
      @symbols = ();
    } else {
      local $_ = $_;
      my $minus = s/^-//;
      my $all = $_ eq 'all';
      Carp::carp "Illegal symbol for tracing ($_)" unless $all || $pack->can($_);
      $minus ? push(@notrace, $all ? @list : $_) : push(@symbols, $all ? @list : $_);
    }
  }
  foreach (@symbols) { *$_ = \&defaultlog }
  foreach (@notrace) { *$_ = sub {} }
}

# ======================================================================

package SOAP::Custom::XML::Data;

use vars qw(@ISA $AUTOLOAD);
@ISA = qw(SOAP::Data);

use overload fallback => 1, '""' => sub { shift->value };

sub _compileit {
  no strict 'refs';
  my $method = shift;
  *$method = sub { 
    return __PACKAGE__->SUPER::name($method => $_[0]->attr->{$method})
      if exists $_[0]->attr->{$method};
    my @elems = grep {
      ref $_ && UNIVERSAL::isa($_ => __PACKAGE__) && $_->SUPER::name =~ /(^|:)$method$/
    } $_[0]->value;
    return wantarray? @elems : $elems[0];
  }
}

sub BEGIN { foreach (qw(name type)) { _compileit($_) } }

sub AUTOLOAD {
  my $method = substr($AUTOLOAD, rindex($AUTOLOAD, '::') + 2);
  return if $method eq 'DESTROY';

  _compileit($method);
  goto &$AUTOLOAD;
}

# ======================================================================

package SOAP::Custom::XML::Deserializer;

use vars qw(@ISA);
@ISA = qw(SOAP::Deserializer);

sub decode_value {
  my $self = shift;
  my $ref = shift;
  my($name, $attrs, $childs, $value) = @$ref;

  # base class knows what to do with it
  return $self->SUPER::decode_value($ref) if exists $attrs->{href};

  SOAP::Custom::XML::Data
    -> SOAP::Data::name($name) 
    -> attr($attrs)
    -> set_value(ref $childs && @$childs ? map(($self->decode_object($_))[1], @$childs) : $value);
}

# ======================================================================

package SOAP::Schema::Deserializer;

use vars qw(@ISA);
@ISA = qw(SOAP::Custom::XML::Deserializer);

# ======================================================================

package SOAP::Schema::WSDL;

sub parse {
  shift if UNIVERSAL::isa($_[0] => __PACKAGE__);
  my $s = shift;
  my @result;
  foreach ($s->service) {
    my $name = $_->name;
    my %services;
    foreach ($_->port) {
      my $binding = SOAP::Utils::disqualify($_->binding);
      my $endpoint = $_->address->location;
      foreach ($s->binding) {
        next unless $_->name eq $binding;
        my $porttype = SOAP::Utils::disqualify($_->type);
        foreach ($_->operation) {
          my $opername = $_->name;
          my $soapaction = $_->operation->soapAction;
          my $namespace = $_->input->body->namespace;
          my @parts;
          foreach ($s->portType) {
            next unless $_->name eq $porttype;
            foreach ($_->operation) {
              next unless $_->name eq $opername;
              my $inputmessage = SOAP::Utils::disqualify($_->input->message);
              foreach ($s->message) {
                next unless $_->name eq $inputmessage;
                @parts = $_->part;
              }
            }
          }
          for ($services{$opername}) {
            $_->{endpoint} = $endpoint;
            $_->{soapaction} = $soapaction;
            $_->{uri} = $namespace;
            $_->{parameters} = [@parts];
          }
        }
      }
    }
    # fix nonallowed characters in package name, and add 's' if started with digit
    for ($name) { s/\W+/_/g; s/^(\d)/s$1/ } 
    push @result, $name => \%services;
  }
  return @result;
}  

# ======================================================================

package SOAP::Schema;

use Carp ();

sub DESTROY { SOAP::Trace::objects('()') }

sub new { 
  my $self = shift;

  unless (ref $self) {
    my $class = ref($self) || $self;
    $self = bless {
      _deserializer => SOAP::Schema::Deserializer->new,
    } => $class;
   
    SOAP::Trace::objects('()');
  }

  Carp::carp "Odd (wrong?) number of parameters in new()" if $^W && (@_ & 1); 
  while (@_) { my $method = shift; $self->$method(shift) if $self->can($method) }

  return $self;
}

sub BEGIN {
  no strict 'refs';
  for my $method (qw(deserializer schema services)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = shift->new;
      @_ ? ($self->{$field} = shift, return $self) : return $self->{$field};
    }
  }
}

sub parse {
  my $self = shift->new;
  my $s = $self->deserializer->deserialize(shift || $self->access)->valueof('/');
  # here should be something that defines what schema description we want to use
  $self->services({SOAP::Schema::WSDL->parse($s)});
}

sub load {
  my $self = shift->new;
  local $^W; # supress warnings about redefining
  foreach (keys %{$self->services || Carp::croak 'Nothing to load. Schema is not specified'}) { 
    eval $self->stub($_) or Carp::croak "Bad stub: $@";
  }
  $self;
}

sub access { require LWP::UserAgent;
  my $self = shift->new;
  my $url = shift || $self->schema || Carp::croak 'Nothing to access. URL is not specified';
  my $ua = LWP::UserAgent->new;
  my $resp = $ua->request(HTTP::Request->new(GET => $url));
  $resp->is_success ? $resp->content : Carp::croak $resp->status_line;
}

sub stub {
  my $self = shift->new;
  my $package = shift;
  my $services = $self->services->{$package};
  my $schema = $self->schema;
  join("\n", 
    "package $package;\n",
    "# -- generated by SOAP::Lite (v$SOAP::Lite::VERSION) for Perl -- soaplite.com -- Copyright (C) 2000-2001 Paul Kulchenko --",
    ($schema ? "# -- generated from $schema [@{[scalar localtime]}]\n" : "\n"),
    'my %methods = (',
    (map { my $service = $_;
           join("\n", 
                "  $_ => {", 
                map("    $_ => '$services->{$service}{$_}',", qw/endpoint soapaction uri/),
                "    parameters => [",
                map("      SOAP::Data->new(name => '" . $_->name . 
                           "', type => '" . $_->type . 
                           "', attr => {" . do{ my %attr = %{$_->attr}; join ', ', map {"'$_' => '$attr{$_}'"} grep {/^xmlns:(?!-)/} keys %attr} . 
                    "}),", @{$services->{$service}{parameters}}),
                "    ],\n  },",
               ), 
         } keys %$services),
    ");", <<'EOP');

use SOAP::Lite;
use Exporter;
use Carp ();

use vars qw(@ISA $AUTOLOAD @EXPORT_OK %EXPORT_TAGS);
@ISA = qw(Exporter SOAP::Lite);
@EXPORT_OK = (keys %methods);
%EXPORT_TAGS = ('all' => [@EXPORT_OK]);

no strict 'refs';
for my $method (@EXPORT_OK) {
  my %method = %{$methods{$method}};
  *$method = sub {
    my $self = UNIVERSAL::isa($_[0] => __PACKAGE__) 
      ? ref $_[0] ? shift # OBJECT
                  # CLASS, either get self or create new and assign to self
                  : (shift->self || __PACKAGE__->self(__PACKAGE__->new))
      # function call, either get self or create new and assign to self
      : (__PACKAGE__->self || __PACKAGE__->self(__PACKAGE__->new));
    $self->proxy($method{endpoint} || Carp::croak "No server address (proxy) specified") unless $self->proxy;
    my @templates = @{$method{parameters}};
    my $som = $self
      -> endpoint($method{endpoint})
      -> uri($method{uri})
      -> on_action(sub{qq!"$method{soapaction}"!})
      -> call($method => map {shift(@templates)->value($_)} @_); 
    UNIVERSAL::isa($som => 'SOAP::SOM') ? wantarray ? $som->paramsall : $som->result 
                                        : $som;
  }
}

1;
EOP
}

# ======================================================================

package SOAP;

use vars qw($AUTOLOAD);

my $soap; # shared between SOAP and SOAP::Lite packages

{ no strict 'refs';
  *AUTOLOAD = sub {
    local($1,$2);
    my($package, $method) = $AUTOLOAD =~ m/(?:(.+)::)([^:]+)$/;
    return if $method eq 'DESTROY';

    my $soap = ref $_[0] && UNIVERSAL::isa($_[0] => 'SOAP::Lite') ? $_[0] : $soap;

    my $uri = URI->new($soap->uri);
    my $currenturi = $uri->path;
    $package = 
      ref $_[0] && UNIVERSAL::isa($_[0] => 'SOAP::Lite') ? $currenturi :
      $package eq 'SOAP' ? ref $_[0] || ($_[0] eq 'SOAP' 
        ? $currenturi || Carp::croak "URI is not specified for method call" : $_[0]) :
      $package eq 'main' ? $currenturi || $package  
                         : $package;

    # drop first parameter if it's a class name
    {
      my $pack = $package;
      for ($pack) { s!^/!!; s!/!::!g }
      shift @_ if !ref $_[0] && ($_[0] eq $pack || $_[0] eq 'SOAP') || 
                   ref $_[0] && UNIVERSAL::isa($_[0] => 'SOAP::Lite');
    }

    for ($package) { s!::!/!g; s!^/?!/!; }
    $uri->path($package);

    my $som = $soap->uri($uri->as_string)->call($method => @_);
    UNIVERSAL::isa($som => 'SOAP::SOM') ? wantarray ? $som->paramsall : $som->result
                                        : $som;
  };
}

# ======================================================================

package SOAP::Lite;

use vars qw($AUTOLOAD @ISA);
use Carp ();
use URI;

@ISA = qw(SOAP::Cloneable);

# provide access to global/autodispatched object
sub self { @_ > 1 ? $soap = $_[1] : $soap } 

# no more warnings about "used only once"
*UNIVERSAL::AUTOLOAD if 0; 

sub autodispatched { \&{*UNIVERSAL::AUTOLOAD} eq \&{*SOAP::AUTOLOAD} };

sub import {
  my $pkg = shift;
  my $caller = caller;
  no strict 'refs'; 

  # emulate 'use SOAP::Lite 0.99' behavior
  $pkg->require_version(shift) if defined $_[0] && $_[0] =~ /^\d/;

  while (@_) {
    my $command = shift;

    my @parameters = UNIVERSAL::isa($_[0] => 'ARRAY') ? @{shift()} : splice(@_)
      unless $command eq 'autodispatch';
    if ($command eq 'autodispatch' || $command eq 'dispatch_from') { 
      $soap = ($soap||$pkg)->new;
      no strict 'refs';
      foreach ($command eq 'autodispatch' ? 'UNIVERSAL' : @parameters) {
        my $sub = "${_}::AUTOLOAD";
        defined &{*$sub}
          ? (\&{*$sub} eq \&{*SOAP::AUTOLOAD} ? () : Carp::croak "$sub already assigned and won't work with DISPATCH. Died")
          : (*$sub = *SOAP::AUTOLOAD);
      }
    } elsif ($command eq 'service' || $command eq 'schema') {
      warn "'schema =>' interface is changed. Use 'service =>' instead\n" 
        if $command eq 'schema' && $^W;
      foreach (keys %{SOAP::Schema->schema(shift(@parameters))->parse->load->services}) {
        $_->export_to_level(1, undef, @parameters ? @parameters : ':all');
      }
    } elsif ($command eq 'debug' || $command eq 'trace') { 
      SOAP::Trace->import(@parameters ? @parameters : 'all');
    } elsif ($command eq 'import') {
      local $^W; # supress warnings about redefining
      my $package = shift(@parameters);
      $package->export_to_level(1, undef, @parameters ? @parameters : ':all') if $package;
    } else {
      Carp::carp "Odd (wrong?) number of parameters in import(), still continue" if $^W && !(@parameters & 1);
      $soap = ($soap||$pkg)->new($command, @parameters);
    }
  }
}

sub DESTROY { SOAP::Trace::objects('()') }

sub new { 
  my $self = shift;

  unless (ref $self) {
    my $class = ref($self) || $self;
    $self = ref $soap ? $soap->clone : {
      _transport => SOAP::Transport->new,
      _serializer => SOAP::Serializer->new,
      _deserializer => SOAP::Deserializer->new,
      _on_action => sub { sprintf '"%s#%s"', shift || '', shift },
      _on_fault => sub {ref $_[1] ? return $_[1] : Carp::croak $_[0]->transport->is_success ? $_[1] : $_[0]->transport->status},
    };
    bless $self => $class;
   
    $self->on_nonserialized($self->on_nonserialized || $self->serializer->on_nonserialized);
    SOAP::Trace::objects('()');
  }

  Carp::carp "Odd (wrong?) number of parameters in new()" if $^W && (@_ & 1); 
  while (@_) { my($method, $params) = splice(@_,0,2);
    $self->can($method) 
      ? $self->$method(ref $params eq 'ARRAY' ? @$params : $params)
      : $^W && Carp::carp "Unrecognized parameter '$method' in new()"
  }

  return $self;
}

sub BEGIN {
  no strict 'refs';
  for my $method (qw(endpoint transport serializer deserializer outputxml on_action on_fault on_nonserialized)) {
    my $field = '_' . $method;
    *$method = sub {
      my $self = shift->new;
      @_ ? ($self->{$field} = shift, return $self) : return $self->{$field};
    }
  }
  for my $method (qw(proxy)) {
    *$method = sub { 
      my $self = shift->new;
      @_ ? ($self->transport->$method(@_), return $self) : return $self->transport->$method();
    }
  }                                                
  for my $method (qw(autotype readable namespace encodingspace multirefinplace encoding typelookup uri header maptype)) {
    *$method = sub { 
      my $self = shift->new;
      @_ ? ($self->serializer->$method(@_), return $self) : return $self->serializer->$method();
    }
  }                                                
}

sub service {
  my $field = '_service';
  my $self = shift->new;
  return $self->{$field} unless @_;

  my %services = %{SOAP::Schema->schema($self->{$field} = shift)->parse->load->services};

  Carp::croak "Cannot activate service description with multiple services through this interface\n" 
    if keys %services > 1; 
  return (keys %services)[0]->new;
}

sub schema {
  warn "SOAP::Lite->schema(...) interface is changed. Use ->service() instead\n" if $^W;
  shift->service(@_);
}

sub on_debug { 
  my $self = shift; 
  # comment this warning for now, till we redesign SOAP::Trace (2001/02/20)
  # Carp::carp "'SOAP::Lite->on_debug' method is deprecated. Instead use 'SOAP::Lite +debug ...'" if $^W;
  SOAP::Trace->import(debug => shift);
  $self;
}

sub AUTOLOAD {
  my $method = substr($AUTOLOAD, rindex($AUTOLOAD, '::') + 2);
  return if $method eq 'DESTROY';

  ref $_[0] or Carp::croak qq!Can't locate class method "$method" via package "! . __PACKAGE__ .'"';

  no strict 'refs';
  *$AUTOLOAD = sub { shift->call($method => @_) };
  goto &$AUTOLOAD;
}

sub call { SOAP::Trace::trace('()');
  my $self = shift;

  return $self->{_call} unless @_;

  my $serializer = $self->serializer;

  $serializer->on_nonserialized($self->on_nonserialized);
  my $response = $self->transport->send_receive(
    endpoint => $self->endpoint, 
    action   => scalar($self->on_action->($serializer->uriformethod($_[0]))),
    envelope => $serializer->envelope(method => shift, @_), # leave only parameters
    encoding => $serializer->encoding,
  );

  return $response if $self->outputxml;

  # deserialize and store result
  my $result = $self->{_call} = eval { $self->deserializer->deserialize($response) } if $response;

  if (!$self->transport->is_success || # transport fault
      $@ ||                            # not deserializible
      # fault message even if transport OK 
      # or no transport error (for example, fo TCP, POP3, IO implementations)
      UNIVERSAL::isa($result => 'SOAP::SOM') && $result->fault) {
    return $self->{_call} = ($self->on_fault->($self, $@ ? $@ . ($response || '') : $result) || $result);
  }

  return unless $response; # nothing to do for one-ways

  # little bit tricky part that binds in/out parameters
  if (UNIVERSAL::isa($result => 'SOAP::SOM') && 
      ($result->paramsout || $result->headers) && 
      $serializer->signature) {
    my $num = 0;
    my %signatures = map {s/(^|$;)$SOAP::Constants::NSMASK:/$1/; $_ => $num++} @{$serializer->signature};
    for ($result->dataof(SOAP::SOM::paramsout), $result->dataof(SOAP::SOM::headers)) {
      my $signature = join $;, map {s/^$SOAP::Constants::NSMASK://; $_} $_->name, $_->type;
      if (exists $signatures{$signature}) {
        my $param = $signatures{$signature};
        my($value) = $_->value; # take first value
        UNIVERSAL::isa($_[$param] => 'SOAP::Data') ? $_[$param]->SOAP::Data::value($value) :
        UNIVERSAL::isa($_[$param] => 'ARRAY')      ? (@{$_[$param]} = @$value) :
        UNIVERSAL::isa($_[$param] => 'HASH')       ? (%{$_[$param]} = %$value) :
        UNIVERSAL::isa($_[$param] => 'SCALAR')     ? (${$_[$param]} = $$value) :
                                                     ($_[$param] = $value)
      }
    }
  }
  return $result;
}

# ======================================================================

package SOAP::Lite::COM;

require SOAP::Lite;

sub required {
  foreach (qw(
    URI::_foreign URI::http URI::https
    LWP::Protocol::http LWP::Protocol::https LWP::Authen::Basic LWP::Authen::Digest
    HTTP::Daemon Compress::Zlib SOAP::Transport::HTTP)) {
    eval join ';', 'local $SIG{__DIE__}', "require $_";
  }
}

sub new    { required; SOAP::Lite->new(@_) } 

sub create; *create = \&new; # make alias. Somewhere 'new' is registered keyword

sub server { required; shift->new(@_) }

sub instanceof { my $class = shift; eval "require $class"; $class->new(@_) }

sub data   { SOAP::Data->new(@_) }

sub header { SOAP::Header->new(@_) }

sub hash   { +{@_} }

# ======================================================================

1;

__END__

=head1 NAME

SOAP::Lite - Client and server side SOAP implementation

=head1 SYNOPSIS

  use SOAP::Lite;
  print SOAP::Lite
    -> uri('http://www.soaplite.com/Temperatures')
    -> proxy('http://services.soaplite.com/temper.cgi')
    -> f2c(32)
    -> result;
 
The same code with autodispatch: 

  use SOAP::Lite +autodispatch =>
    uri => 'http://www.soaplite.com/Temperatures',
    proxy => 'http://services.soaplite.com/temper.cgi';

  print f2c(32);

Code in OO-style:

  use SOAP::Lite +autodispatch =>
    uri => 'http://www.soaplite.com/Temperatures',
    proxy => 'http://services.soaplite.com/temper.cgi';

  my $temperatures = Temperatures->new(32); # get object
  print $temperatures->as_celsius;          # invoke method

Code with service description:

  use SOAP::Lite;
  print SOAP::Lite
    -> service('http://www.xmethods.net/sd/StockQuoteService.wsdl')
    -> getQuote('MSFT');

Code for SOAP server (CGI):

  use SOAP::Transport::HTTP;
  SOAP::Transport::HTTP::CGI
    -> dispatch_to('/Your/Path/To/Deployed/Modules', 'Module::Name', 'Module::method') 
    -> handle;

Visual Basic client (through COM interface): 

  MsgBox CreateObject("SOAP.Lite").new( _
    "proxy", "http://services.xmethods.net/soap", _
    "uri",   "urn:xmethods-delayed-quotes" _
  ).getQuote("MSFT").result

mod_soap enabled SOAP server: 

  .htaccess

  SetHandler perl-script
  PerlHandler Apache::SOAP
  PerlSetVar dispatch_to "/Your/Path/To/Deployed/Modules, Module::Name"

ASP/VB SOAP server: 

  <%
    Response.ContentType = "text/xml"
    Response.Write(Server.CreateObject("SOAP.Lite") _
      .server("SOAP::Server") _ 
      .dispatch_to("/Your/Path/To/Deployed/Modules") _
      .handle(Request.BinaryRead(Request.TotalBytes)) _
    )
  %>

=head1 DESCRIPTION

SOAP::Lite is a collection of Perl modules which provides a 
simple and lightweight interface to the Simple Object Access Protocol 
(SOAP) both on client and server side.

This version of SOAP::Lite supports the SOAP 1.1 specification ( http://www.w3.org/TR/SOAP ).

The main features of the library are:

=over 3

=item *

Supports SOAP 1.1 spec. 

=item *

Interoperability tests with different implementations: Apache SOAP, Frontier, 
Microsoft SOAP, Microsoft .NET, DevelopMentor, XMethods, 4s4c, Phalanx, 
Kafka, SQLData, Lucin (in Java, Perl, C++, Python, VB, COM, XSLT). 

=item *

Provides COM interface. Single dll (standalone [2.5MB] or minimal [32kB]). 
Works on Windows 9x/Me/NT/2K. Doesn't require ROPE or MSXML. 
Examples in VB, Excel/VBA, C#, ASP, JavaScript, PerlScript and Perl. 

=item *

Provides transparent compression support for HTTP transport. 

=item *

Provides mod_soap module. Make SOAP server with a few lines in .htaccess 
or .conf file. 

=item *

Includes XML::Parser::Lite (regexp-based XML parser) which runs instead 
of XML::Parser where Perl 5.6 runs (even on WinCE) with some limitations. 

=item *

Includes XMLRPC::Lite, implementation of XML-RPC protocol on client and 
server side. All transports and features of SOAP::Lite are available. 

=item *

Supports multipart/form-data MIME attachments. 

=item *

Supports circular linked lists and multiple references. 

=item *

Supports Map datatype (encoding of maps/hashes with arbitrary keys). 

=item *

Supports HTTPS protocol. 

=item *

Provides proxy support. 

=item *

Provides CGI/daemon/mod_perl/Apache::Registry server implementations. 

=item *

Provides TCP server implementation. 

=item *

Provides IO (STDIN/STDOUT/File) server implementation. 

=item *

Provides FTP client implementation. 

=item *

Supports single/multipart MIME attachment (parsing side only). 

=item *

Supports SMTP protocol. 

=item *

Provides POP3 server implementation. 

=item *

Supports M-POST and redirects in HTTP transport. 

=item *

Supports Basic/Digest server authentication. 

=item *

Works with CGI accelerators, like VelociGen and PerlEx. 

=item *

Supports UDDI interface on client side. See UDDI::Lite for details. 

=item *

Supports UDDI publishing API. Examples and documentation provided. 

=item *

Supports WSDL schema with stub and run-time access. 

=item *

Supports blessed object references. 

=item *

Supports arrays (both serialization and deserialization with autotyping). 

=item *

Supports custom serialization. 

=item *

Provides exception transport with custom exceptions 

=item *

Supports Base64 encoding. 

=item *

Supports XML entity encoding. 

=item *

Supports header attributes. 

=item *

Supports dynamic and static class/method binding. 

=item *

Supports objects-by-reference with simple garbage collection and activation. 

=item *

Provides shell for interactive SOAP sessions. 

=item *

Supports out parameters binding. 

=item *

Supports transparent SOAP calls with autodispatch feature. 

=item *

Provides easy services deployment. Put module in specified directory and 
it'll be accessible. 

=item *

Has tests, examples and documentation to let you be up and running in no time.

=back

=head2 WHERE TO FIND EXAMPLES

See F<t/*.t>, F<examples/*.pl> and the module documentation for a client-side 
examples that demonstrate the serialization of a SOAP request, sending it 
via HTTP to the server and receiving the response, and the deserialization 
of the response. See F<examples/server/*> for server-side implementations.

=head1 OVERVIEW OF CLASSES AND PACKAGES

This table should give you a quick overview of the classes provided by the
library.

 SOAP::Lite.pm
 -- SOAP::Lite           -- Main class provides all logic
 -- SOAP::Transport      -- Supports transport architecture
 -- SOAP::Data           -- Provides extensions for serialization architecture
 -- SOAP::Header         -- Provides extensions for header serialization
 -- SOAP::Parser         -- Parses XML file into object tree
 -- SOAP::Serializer     -- Serializes data structures to SOAP package
 -- SOAP::Deserializer   -- Deserializes results of SOAP::Parser into objects
 -- SOAP::SOM            -- Provides access to deserialized object tree
 -- SOAP::Constants      -- Provides access to common constants
 -- SOAP::Trace          -- Provides tracing facilities
 -- SOAP::Schema         -- Provides access and stub(s) for schema(s)
 -- SOAP::Schema::WSDL   -- WSDL implementation for SOAP::Schema
 -- SOAP::Server         -- Handles requests on server side 
 -- SOAP::Server::Object -- Handles objects-by-reference 
 -- SOAP::Fault          -- Provides support for Faults on server side

 SOAP::Transport::HTTP.pm
 -- SOAP::Transport::HTTP::Client  -- Client interface to HTTP transport
 -- SOAP::Transport::HTTP::Server  -- Server interface to HTTP transport
 -- SOAP::Transport::HTTP::CGI     -- CGI implementation of server interface
 -- SOAP::Transport::HTTP::Daemon  -- Daemon implementation of server interface
 -- SOAP::Transport::HTTP::Apache  -- mod_perl implementation of server interface

 SOAP::Transport::POP3.pm
 -- SOAP::Transport::POP3::Server  -- Server interface to POP3 protocol

 SOAP::Transport::MAILTO.pm
 -- SOAP::Transport::MAILTO::Client -- Client interface to SMTP/sendmail

 SOAP::Transport::LOCAL.pm
 -- SOAP::Transport::LOCAL::Client -- Client interface to local transport

 SOAP::Transport::TCP.pm
 -- SOAP::Transport::TCP::Server -- Server interface to TCP protocol
 -- SOAP::Transport::TCP::Client -- Client interface to TCP protocol

 SOAP::Transport::IO.pm
 -- SOAP::Transport::IO::Server -- Server interface to IO transport

=head2 SOAP::Lite

All methods that C<SOAP::Lite> provides can be used for both
setting and retrieving values. If you provide no parameters, you will
get current value, and if parameters are provided, a new value
will be assigned to the object and the method in question will return 
the current object (if not stated otherwise). This is suitable for stacking
these calls like:

  $lite = SOAP::Lite
    -> uri('http://simon.fell.com/calc')
    -> proxy('http://soap.4s4c.com/ssss4c/soap.asp')
  ;

The order is insignificant and you may call the new() method first. If you
don't do it, SOAP::Lite will do it for you. However, the new() method
gives you additional syntax:

  $lite = new SOAP::Lite
    uri => 'http://simon.fell.com/calc',
    proxy => 'http://soap.4s4c.com/ssss4c/soap.asp'
  ;

=over 4

=item new()

new() accepts a hash with method names as keys. It will call the 
appropriate methods together with the passed values. Since new() is 
optional it won't be mentioned anymore.

=item transport()

Provides access to the L</"SOAP::Transport"> object. The object will be created 
for you. You can reassign it (but generally you should not).

=item serializer()

Provides access to the L</"SOAP::Serialization"> object. The object will be 
created for you. You can reassign it (but generally you should not).

=item proxy()

Shortcut for C<< transport->proxy() >>. This lets you specify an endpoint 
(service address) and also loads the required module at the same time. It is 
required for dispatching SOAP calls. The name of the module will be defined 
depending on the protocol specific for the endpoint. The prefix 
C<SOAP::Transport> will be prepended, the module will be loaded and object of 
class (with appended C<::Client>) will be created. 

For example, for F<http://localhost/>, the class for creating objects will 
look for C<SOAP::Transport:HTTP::Client>;

In addition to endpoint parameter, proxy() can accept any transport specific
parameters that could be passed as name => value pairs. For example, to 
specify proxy settings for HTTP protocol you may do:

  $soap->proxy('http://endpoint.server/', 
               proxy => ['http' => 'http://my.proxy.server/']);

Notice that since proxy (second one) expects to get more than one 
parameter you should wrap them in array.

Another useful example can be the client that is sensitive to cookie-based
authentication. You can provide this with:

  $soap->proxy('http://localhost/', 
               cookie_jar => HTTP::Cookies->new(ignore_discard => 1));

You may specify timeout for HTTP transport with following code:

  $soap->proxy('http://localhost/', timeout => 5);

=item endpoint()

Lets you specify an endpoint B<without> changing/loading the protocol module. 
This is useful for switching endpoints without switching protocols. You should 
call C<proxy()> first. No checks for protocol equivalence will be made.

=item outputxml()

Lets you specify the kind of output from all method calls. If C<true>, all 
methods will return unprocessed, raw XML code. You can parse it with 
XML::Parser, SOAP::Deserializer or any other appropriate module.

=item autotype()

Shortcut for C<< serializer->autotype() >>. This lets you specify whether 
the serializer will try to make autotyping for you or not. Default setting 
is C<true>.

=item readable()

Shortcut for C<< serializer->readable() >>. This lets you specify the format 
for the generated XML code. Carriage returns <CR> and indentation will be 
added for readability. Useful in the case you want to see the generated code 
in a debugger. By default, there are no additional characters in generated 
XML code. 

=item namespace()

Shortcut for C<< serializer->namespace() >>. This lets you specify the default
namespace for generated envelopes (C<'SOAP-ENV'> by default).

=item encodingspace()

Shortcut for C<< serializer->encodingspace() >>. This lets you specify the 
default encoding namespace for generated envelopes (C<'SOAP-ENC'> by default).

=item encoding()

Shortcut for C<< serializer->encoding() >>. This lets you specify the encoding 
for generated envelopes. For now it will not actually change envelope
encoding, it will just modify the XML header (C<'UTF-8'> by default).

=item typelookup()

Shortcut for C<< serializer->typelookup() >>. This gives you access to 
the C<typelookup> table that is used for autotyping. For more information
see L</"SOAP::Serializer">.

=item uri()

Shortcut for C<< serializer->uri() >>. This lets you specify the uri for SOAP 
methods. Nothing is specified by default and your call will definitely fail 
if you don't specify the required uri. 

B<WARNING>: URIs are just identifiers. They may B<look like URLs>, but they are
not guaranteed to point to anywhere and shouldn't be used as such pointers.
URIs assume to be unique within the space of all XML documents, so consider
them as unique identifiers and nothing else.

=item multirefinplace()

Shortcut for C<< serializer->multirefinplace() >>. If true, the serializer will
put values for multireferences in the first occurrence of the reference. 
Otherwise it will be encoded as top independent element, right after C<method>
element inside C<Body>. Default value is C<false>. 

=item header() 

B<DEPRECATED>: Use SOAP::Header instead. 

Shortcut for C<< serializer->header() >>. This lets you specify the header for 
generated envelopes. You can specify C<root>, C<mustUnderstand> or any
other header using L</"SOAP::Data"> class:

  $serializer = SOAP::Serializer->envelope('method' => 'mymethod', 1,
    SOAP::Header->name(t1 => 5)->mustUnderstand(1),
    SOAP::Header->name(t2 => 7)->mustUnderstand(2),
  );

will be serialized into:

  <SOAP-ENV:Envelope ...attributes skipped>
    <SOAP-ENV:Header>
      <t1 xsi:type="xsd:int" SOAP-ENV:mustUnderstand="1">5</t1>
      <t2 xsi:type="xsd:int" SOAP-ENV:mustUnderstand="1">7</t2>
    </SOAP-ENV:Header>
    <SOAP-ENV:Body>
      <namesp1:mymethod xmlns:namesp1="urn:SOAP__Serializer">
        <c-gensym6 xsi:type="xsd:int">1</c-gensym6>
      </namesp1:mymethod>
    </SOAP-ENV:Body>
  </SOAP-ENV:Envelope>

You can mix C<SOAP::Header> parameters with other parameters and you can also
return C<SOAP::Header> parameters as a result of a remote call. They will be 
placed into the header. See C<My::Parameters::addheader> as an example.

=item on_action()

This lets you specify a handler for C<on_action event>. It is triggered when 
creating SOAPAction. The default handler will set SOAPAction to 
C<"uri#method">. You can change this behavior globally 
(see L</"DEFAULT SETTINGS">) or locally, for a particular object.

=item on_fault()

This lets you specify a handler for C<on_fault> event. The default behavior is 
to B<die> on an transport error and to B<do nothing> on other error conditions. You 
may change this behavior globally (see L</"DEFAULT SETTINGS">) or locally, for a 
particular object.

=item on_debug()

This lets you specify a handler for C<on_debug event>. Default behavior is to 
do nothing. Use C<+trace/+debug> option for SOAP::Lite instead. If you use if 
be warned that since this method is just interface to C<+trace/+debug> it has
B<global> effect, so if you install it for one object it'll be in effect for 
all subsequent calls (even for other objects).

=item on_nonserialized()

This lets you specify a handler for C<on_nonserialized event>. The default 
behavior is to produce a warning if warnings are on for everything that cannot 
be properly serialized (like CODE references or GLOBs).

=item call()

Provides alternative interface for remote method calls. You can always
run C<< SOAP::Lite->new(...)->method(@parameters) >>, but call() gives
you several additional options:

=over 4

=item prefixed method

If you want to specify prefix for generated method's element one of the
available options is do it with call() interface:

  print SOAP::Lite
    -> new(....)
    -> call('myprefix:method' => @parameters)
    -> result;

This example will work on client side only. If you want to change prefix
on server side you should override default serializer. See 
F<examples/server/soap.*> for examples. 

=item access to any method

If for some reason you want to get access to remote procedures that have 
the same name as methods of SOAP::Lite object these calls (obviously) won't 
be dispatched. In that case you can originate your call trough call():

  print SOAP::Lite
    -> new(....)
                   # don't forget to specify CLASS name as the first parameter
    -> call(new => @parameters) 
    -> result;

=item implementation of OO interface

With L<autodispatch|/"AUTODISPATCHING AND SOAP:: PREFIX"> you can make CLASS/OBJECT calls like:

  my $obj = CLASS->new(@parameters);
  print $obj->method;

However, because of side effects L<autodispatch|/"AUTODISPATCHING AND SOAP:: PREFIX"> has, it's not always 
possible to use this syntax. call() provides you alternative:

  # you should specify uri()
  my $soap = SOAP::Lite
    -> uri('http://my.own.site/CLASS') # <<< CLASS goes here
    # ..... other parameters
  ;

  my $obj = $soap->call(new => @parameters)->result;
  print $soap->call(method => $obj)->result;
  # $obj object will be updated here if necessary, 
  # as if you call $obj->method() and method() updates $obj

  # Update of modified object MAY not work if server on another side 
  # is not SOAP::Lite

=item ability to set method's attributes

Additionally this syntax lets you specify attributes for method element:

  print SOAP::Lite
    -> new(....)
    -> call(SOAP::Data->name('method')->attr({xmlns => 'mynamespace'})
            => @parameters)
    -> result;

You can specify B<any> attibutes and C<name> of C<SOAP::Data> element becomes
name of method. Everything else except attributes is ignored and parameters
should be provided as usual.

Be warned, that though you have more control using this method, you B<should> 
specify namespace attribute for method explicitely, even if you made uri() 
call earlier. So, if you have to have namespace on method element, instead of:

  print SOAP::Lite
    -> new(....)
    -> uri('mynamespace') # will be ignored 
    -> call(SOAP::Data->name('method') => @parameters)
    -> result;

do

  print SOAP::Lite
    -> new(....)
    -> call(SOAP::Data->name('method')->attr({xmlns => 'mynamespace'})
            => @parameters)
    -> result;

because in the former call uri() will be ignored and namespace won't be 
specified. If you run script with C<-w> option (as recommended) SOAP::Lite
gives you a warning:

  URI is not provided as attribute for method (method)

Moreover, it'll become fatal error if you try to call it with prefixed name:

  print SOAP::Lite
    -> new(....)
    -> uri('mynamespace') # will be ignored 
    -> call(SOAP::Data->name('a:method') => @parameters)
    -> result;

gives you:

  Can't find namespace for method (a:method)

because nothing is associated with prefix C<'a'>. 

=back

One more comment. One case when SOAP::Lite will change something that 
you specified is when you specified prefixed name and empty namespace name:

  print SOAP::Lite
    -> new(....)
    -> uri('') 
    -> call('a:method' => @parameters)
    -> result;

This code will generate:

  <method xmlns="">....</method>

instead of 

  <a:method xmlns:a="">....</method>

because later is not allowed according to XML Namespace specification.

In all other aspects C<< ->call(mymethod => @parameters) >> is just a 
synonim for C<< ->mymethod(@parameters) >>.

=item self()

Returns object reference to B<global> defaul object specified with 
C<use SOAP::Lite ...> interface. Both class method and object method return
reference to B<global> object, so:

  use SOAP::Lite
    proxy => 'http://my.global.server'
  ;

  my $soap = SOAP::Lite->proxy('http://my.local.server');

  print $soap->self->proxy;

prints C<'http://my.global.server'> (the same as C<< SOAP::Lite->self->proxy >>). 
See L</"DEFAULT SETTINGS"> for more information.

=item dispatch_from()

Does exactly the same as L<autodispatch|/"AUTODISPATCHING AND SOAP:: PREFIX">
does, but doesn't install UNIVERSAL::AUTOLOAD handler and only install
AUTOLOAD handlers in specified classes. Can be used only with C<use SOAP::Lite ...>
clause and should be specified first:

  use SOAP::Lite 
    dispatch_to => ['A', 'B'], # use "dispatch_to => 'A'" for one class
    uri => ....,
    proxy => ....,
  ;

  A->a;
  B->b;

=back

=head2 SOAP::Data

You can use this class if you want to specify a value, a name, atype, a uri or 
attributes for SOAP elements (use C<value()>, C<name()>, C<type()>, 
C<uri()> and C<attr()> methods correspondingly). 
For example, C<< SOAP::Data->name('abc')->value(123) >> will be serialized
into C<< <abc>123</abc> >>, as well as will C<< SOAP::Data->name(abc => 123) >>.
Each of them (except the value() method) can accept a value as the second 
parameter. All methods return the current value if you call them without 
parameters. The return the object otherwise, so you can stack them. See tests 
for more examples. You can import these methods with: 
   
  SOAP::Data->import('name'); 

or 

  import SOAP::Data 'name'; 

and then use C<< name(abc => 123) >> for brevity. 

An interface for specific attributes is also provided. You can use the C<actor()>,
C<mustUnderstand()>, C<encodingStyle()> and C<root()> methods to set/get
values of the correspondent attributes.

  SOAP::Data
    ->name(c => 3)
    ->encodingStyle('http://xml.apache.org/xml-soap/literalxml')

will be serialized into:

  <c SOAP-ENV:encodingStyle="http://xml.apache.org/xml-soap/literalxml"
     xsi:type="xsd:int">3</c>

=head2 SOAP::Serializer

Usually you don't need to interact directly with this module. The only 
case when you need it, it when using autotyping. This feature lets you specify 
types for your data according to your needs as well as to introduce new
data types (like ordered hash for example). 

You can specify a type with C<< SOAP::Data->type(float => 123) >>. During
the serialization stage the module will try to serialize your data with the 
C<as_float> method. It then calls the C<typecast> method (you can override it 
or inherit your own class from L</"SOAP::Data">) and only then it will try to 
serialize it according to data type (C<SCALAR>, C<ARRAY> or C<HASH>). For example:

  SOAP::Data->type('ordered_hash' => [a => 1, b => 2]) 

will be serialized as an ordered hash, using the C<as_ordered_hash> method.

If you do not specify a type directly, the serialization module will try
to autodefine the type for you according to the C<typelookup> hash. It contains 
the type name as key and the following 3-element array as value:

  priority, 
  check_function (CODE reference), 
  typecast function (METHOD name or CODE reference)

For example, if you want to add C<uriReference> to autodefined types,
you should add something like this:

  $s->typelookup->{uriReference} =
    [11, sub { $_[0] =~ m!^http://! }, 'as_uriReference'];

and add the C<as_uriReference> method to the L</"SOAP::Serializer"> class:

  sub SOAP::Serializer::as_uriReference {
    my $self = shift;
    my($value, $name, $type, $attr) = @_;
    return [$name, {'xsi:type' => 'xsd:uriReference', %$attr}, $value];
  }

The specified methods will work for both autotyping and direct typing, so you
can use either 

  SOAP::Data->type(uriReference => 'http://yahoo.com')>

or just 

  'http://yahoo.com'

and it will be serialized into the same type. For more examples see C<as_*> 
methods in L</"SOAP::Serializer">.

The SOAP::Serializer provides you with C<autotype()>, C<readable()>, C<namespace()>,
C<encodingspace()>, C<encoding()>, C<typelookup()>, C<uri()>, C<multirefinplace()> and 
C<envelope()> methods. All methods (except C<envelope()>) are described in the
L</"SOAP::Lite"> section.

=over 4

=item envelope()

This method allows you to build three kind of envelopes depending on the first 
parameter:

=over 4

=item method

  envelope(method => 'methodname', @parameters);

or

  method('methodname', @parameters);

Lets you build a request/response envelope.

=item fault

  envelope(fault => 'faultcode', 'faultstring', $details);

or 
  
  fault('faultcode', 'faultstring', $details);

Lets you build a fault envelope. Faultcode will be properly qualified and
details could be string or object.

=item freeform

  envelope(freeform => 'something that I want to serialize');

or

  freeform('something that I want to serialize');
           
Reserved for nonRPC calls. Lets you build your own payload inside a SOAP 
envelope. All SOAP 1.1 specification rules are enforced, except method 
specific ones. See UDDI::Lite as example.

=back

=back 

For more examples see tests and SOAP::Transport::HTTP.pm

=head2 SOAP::SOM

All calls you are making through object oriented interface will 
return SOAP::SOM object, and you can access actual values with it.
Next example gives you brief overview of the class:

  my $soap = SOAP::Lite .....;
  my $som = $soap->method(@parameters);

  if ($som->fault) { # will be defined if Fault element is in the message
    print $som->faultdetail; # returns value of 'detail' element as
                             # string or object
    $som->faultcode;   #
    $som->faultstring; # also available
    $som->faultactor;  # 
  } else {
    $som->result; # gives you access to result of call  
                  # it could be any data structure, for example reference 
                  # to array if server didi something like: return [1,2];
  
    $som->paramsout; # gives you access to out parameters if any
                     # for example, you'll get array (1,2) if
                     # server returns ([1,2], 1, 2); 
                     # [1,2] will be returned as $som->result
                     # and $som->paramsall will return ([1,2], 1, 2)
                     # see section IN/OUT, OUT PARAMETERS AND AUTOBINDING
                     # for more information

    $som->paramsall; # gives access to result AND out parameters (if any)
                     # and returns them as one array
  
    $som->valueof('//myelement'); # returns value(s) (as perl data) of
                                  # 'myelement' if any. All elements in array
                                  # context and only first one in scalar
  
    $h = $som->headerof('//myheader'); # returns element as SOAP::Header, so
                                       # you can access attributes and values
                                       # with $h->mustUnderstand, $h->actor
                                       # or $h->attr (for all attributes)
  }
   
SOAP::SOM object gives you access to the deserialized envelope via several 
methods. All methods accept a node path (similar to XPath notations). 
SOM interprets '/' as the root node, '//' as relative location path
('//Body' will find all bodies in document, as well as 
'/Envelope//nums' will find all 'nums' nodes under Envelope node),
'[num]' as node number and '[op num]' with C<op> being a comparison 
operator ('<', '>', '<=', '>=', '!', '=').

All nodes in nodeset will be returned in document order.

=over 4

=item match()

Accepts a path to a node and returns true/false in a boolean context and
a SOM object otherwise. C<valueof()> and C<dataof()> can be used to get 
value(s) of matched node(s).

=item valueof()

Returns the value of a (previously) matched node. It accepts a node path. 
In this case, it returns the value of matched node, but does not change the current
node. Suitable when you want to match a  node and then navigate through
node children:

  $som->match('/Envelope/Body/[1]'); # match method
  $som->valueof('[1]');              # result
  $som->valueof('[2]');              # first out parameter (if present)

The returned value depends on the context. In a scalar context it will return 
the first element from matched nodeset. In an array context it will return 
all matched elements.

=item dataof()        

Same as C<valueof()>, but it returns a L</"SOAP::Data"> object, so you can get 
access to the name, the type and attributes of an element.

=item headerof()

Same as C<dataof()>, but it returns L</"SOAP::Header"> object, so you can get 
access to the name, the type and attributes of an element. Can be used for 
modifying headers (if you want to see updated header inside Header element, 
it's better to use this method instead of C<dataof()> method).

=item namespaceuriof()

Returns the uri associated with the matched element. This uri can also be 
inherited, for example, if you have 

  <a xmlns='http://my.namespace'>
    <b>
       value
    </b>
  </a>

this method will return same value for 'b' element as for 'a'.

=back

SOAP::SOM also provides  methods for direct access to the envelope, the body, 
methods and parameters (both in and out). All these methods return real
values (in most cases it will be a hash reference), if called as object
method. Returned values also depend on context: in an array context it will 
return an array of values and in scalar context it will return the first
element. So, if you want to access the first output parameter, you can call
C<< $param = $som->paramsout >>; 
and you will get it regardless of the actual number of output parameters. 
If you call it as class function (for example, SOAP::SOM::method)
it returns an XPath string that matches the current element 
('/Envelope/Body/[1]' in case of 'method'). The method will return C<undef> 
if not present OR if you try to access an element that has an C<xsi:null="1"> 
attribute. To distinguish between these two cases you can first access the 
C<match()> method that will return true/false in a boolean context and then 
get the real value:

  if ($som->match('//myparameter')) {
    $value = $som->valueof; # can be undef too
  } else {
    # doesn't exist
  }

=over 4

=item root()

Returns the value (as hash) of the root element. Do exactly the same as 
C<< $som->valueof('/') >> does.

=item envelope()

Returns the value (as hash) of the C<Envelope> element. Keys in this hash will be 
'Header' (if present), 'Body' and any other (optional) elements. Values will 
be the deserialized header, body, and elements, respectively.
If called as function (C<SOAP::SOM::envelope>) it will return a Xpath string 
that matches the envelope content. Useful when you want just match it and 
then iterate over the content by yourself. Example:

  if ($som->match(SOAP::SOM::envelope)) {
    $som->valueof('Header'); # should give access to header if present
    $som->valueof('Body');   # should give access to body
  } else {
    # hm, are we doing SOAP or what?
  }

=item header()

Returns the value (as hash) of the C<Header> element. If you want to access all 
attributes in the header use:

  # get element as SOAP::Data object 
  $transaction = $som->match(join '/', SOAP::SOM::header, 'transaction')->dataof;
  # then you can access all attributes of 'transaction' element
  $transaction->attr; 

=item headers()

Returns a node set of values with deserialized headers. The difference between 
the C<header()> and C<headers()> methods is that the first gives you access 
to the whole header and second to the headers inside the 'Header' tag:

  $som->headerof(join '/', SOAP::SOM::header, '[1]');
  # gives you first header as SOAP::Header object

  ($som->headers)[0];
  # gives you value of the first header, same as
  $som->valueof(join '/', SOAP::SOM::header, '[1]');

  $som->header->{name_of_your_header_here}
  # gives you value of name_of_your_header_here

=item body()

Returns the value (as hash) of the C<Body> element. 

=item fault()

Returns the value (as hash) of C<Fault> element: C<faultcode>, C<faultstring> and
C<detail>. If C<Fault> element is present, C<result()>, C<paramsin()>, 
C<paramsout()> and C<method()> will return an undef.

=item faultcode()

Returns the value of the C<faultcode> element if present and undef otherwise.

=item faultstring()

Returns the value of the C<faultstring> element if present and undef otherwise.

=item faultactor()

Returns the value of the C<faultactor> element if present and undef otherwise.

=item faultdetail()

Returns the value of the C<detail> element if present and undef otherwise.

=item method()

Returns the value of the method element (all input parameters if you call it on 
a deserialized request envelope, and result/output parameters if you call it
on a deserialized response envelope). Returns undef if the 'Fault' element is 
present.

=item result()

Returns the value of the C<result> of the method call. In fact, it will return 
the first child element (in document order) of the method element.

=item paramsin()

Returns the value(s) of all passed parameters.

=item paramsout()

Returns value(s) of the output parameters. 

=item paramsall()

Returns value(s) of the result AND output parameters as one array.

=back

=head2 SOAP::Schema

SOAP::Schema gives you ability to load schemas and create stubs according 
to these schemas. Different syntaxes are provided:

=over 4

=item *

  use SOAP::Lite
    service => 'http://www.xmethods.net/sd/StockQuoteService.wsdl',
    # service => 'file:/your/local/path/StockQuoteService.wsdl',
    # service => 'file:./StockQuoteService.wsdl',
  ;
  print getQuote('MSFT'), "\n";

=item *

  use SOAP::Lite;
  print SOAP::Lite
    -> service('http://www.xmethods.net/sd/StockQuoteService.wsdl')
    -> getQuote('MSFT'), "\n";

=item *

  use SOAP::Lite;
  my $service = SOAP::Lite
    -> service('http://www.xmethods.net/sd/StockQuoteService.wsdl');
  print $service->getQuote('MSFT'), "\n";

=back

You can create stub with B<stubmaker> script:

  perl stubmaker.pl http://www.xmethods.net/sd/StockQuoteService.wsdl

and you'll be able to access SOAP services in one line:

  perl "-MStockQuoteService qw(:all)" -le "print getQuote('MSFT')" 

or dynamically:

  perl "-MSOAP::Lite service=>'file:./quote.wsdl'" -le "print getQuote('MSFT')"

Other supported syntaxes with stub(s) are:

=over 4

=item *

  use StockQuoteService ':all';
  print getQuote('MSFT'), "\n";

=item *

  use StockQuoteService;
  print StockQuoteService->getQuote('MSFT'), "\n";

=item *

  use StockQuoteService;
  my $service = StockQuoteService->new;
  print $service->getQuote('MSFT'), "\n";

=back

Support for schemas is limited for now. Though module was tested with dozen
different schemas it won't understand complex objects and will work only
with WSDL. 

=head2 SOAP::Trace

SOAP::Trace provides you with a trace/debug facility for the SOAP::Lite 
library. To activate it you need to specify a list of traceable 
events/parts of SOAP::Lite:

  use SOAP::Lite +trace =>
    qw(list of available traces here);

Available events are:

 transport  -- (client) access to request/response for transport layer
 dispatch   -- (server) shows full name of dispatched call 
 result     -- (server) result of method call
 parameters -- (server) parameters for method call
 headers    -- (server) headers of received message
 objects    -- (both)   new/DESTROY calls
 method     -- (both)   parameters for '->envelope(method =>' call
 fault      -- (both)   parameters for '->envelope(fault =>' call
 freeform   -- (both)   parameters for '->envelope(freeform =>' call
 trace      -- (both)   trace enters into some important functions
 debug      -- (both)   details about transport 

For example:

  use SOAP::Lite +trace =>
    qw(method fault);

lets you output the parameter values for all your fault/normal envelopes onto STDERR. 
If you want to log it you can either redirect STDERR to some file

  BEGIN { open(STDERR, '>>....'); }

or (preferably) define your own function for a particular event:

  use SOAP::Lite +trace =>
    method => sub {'log messages here'}, fault => \&log_faults;

You can share the same function for several events:

  use SOAP::Lite +trace =>
    method, fault => \&log_methods_and_faults;

Also you can use 'all' to get all available tracing and use '-' in front of an event to 
disable particular event:

  use SOAP::Lite +trace =>
    all, -transport; # to get all logging without transport messages

Finally,

  use SOAP::Lite +trace; 

will switch all debugging on.

You can use 'debug' instead of 'trace'. I prefer 'trace', others 'debug'. 
Also C<on_debug> is available for backward compatibility, as in

  use SOAP::Lite;

  my $s = SOAP::Lite 
    -> uri('http://tempuri.org/')
    -> proxy('http://beta.search.microsoft.com/search/MSComSearchService.asmx')
    -> on_debug(sub{print@_}) # show you request/response with headers
  ;
  print $s->GetVocabulary(SOAP::Data->name('~:Query' => 'something'))
          ->valueof('//FOUND');

or switch it on individually, with

  use SOAP::Lite +trace => debug;

or
  
  use SOAP::Lite +trace => debug => sub {'do_what_I_want_here'};

Compare this with: 

  use SOAP::Lite +trace => transport;
 
which gives you access to B<actual> request/response objects, so you can even 
set/read cookies or do whatever you want there.

The difference between C<debug> and C<transport> is that C<transport> will get 
a HTTP::Request/HTTP::Response object and C<debug> will get a stringified request 
(NOT OBJECT!). It can also be called in other places too. 

=head2 SOAP::Fault

This class gives you access to Fault generated on server side. To make a
Fault message you might simply die on server side and SOAP processor will 
wrap you message as faultstring element and will transfer Fault on client
side. But in some cases you need to have more control over this process and
SOAP::Fault class gives it to you. To use it, simply die with SOAP::Fault
object as a parameter:

  die SOAP::Fault->faultcode('Server.Custom') # will be qualified
                 ->faultstring('Died in server method')
                 ->faultdetail(bless {code => 1} => 'BadError')
                 ->faultactor('http://www.soaplite.com/custom');

faultdetail() and faultactor() methods are optional and since faultcode and
faultstring are required to represent fault message SOAP::Lite will use
default values ('Server' and 'Application error') if not specified.

=head1 FEATURES AND OPTIONS

=head2 DEFAULT SETTINGS

Though this feature looks similar to L<autodispatch|/"AUTODISPATCHING AND SOAP:: PREFIX"> they have (almost) 
nothing in common. It lets you create default object and all objects 
created after that will be cloned from default object and hence get its 
properties. If you want to provide common proxy() or uri() settings for 
all SOAP::Lite objects in your application you may do:

  use SOAP::Lite
    proxy => 'http://localhost/cgi-bin/soap.cgi',
    uri => 'http://my.own.com/My/Examples'
  ;

  my $soap1 = new SOAP::Lite; # will get the same proxy()/uri() as above
  print $soap1->getStateName(1)->result;

  my $soap2 = SOAP::Lite->new; # same thing as above
  print $soap2->getStateName(2)->result;

  # or you may override any settings you want
  my $soap3 = SOAP::Lite->proxy('http://localhost/'); 
  print $soap3->getStateName(1)->result;

B<Any> SOAP::Lite properties can be propagated this way. Changes in object
copies will not affect global settings and you may still change global
settings with C<< SOAP::Lite->self >> call which returns reference to
global object. Provided parameter will update this object and you can
even set it to C<undef>:

  SOAP::Lite->self(undef);

The C<use SOAP::Lite> syntax also lets you specify default event handlers 
for your code. If you have different SOAP objects and want to share the 
same C<on_action()> (or C<on_fault()> for that matter) handler. You can 
specify C<on_action()> during initialization for every object, but 
you may also do:

  use SOAP::Lite 
    on_action => sub {sprintf '%s#%s', @_}
  ;

and this handler will be the default handler for all your SOAP objects. 
You can override it if you specify a handler for a particular object.
See F<t/*.t> for example of on_fault() handler.

Be warned, that since C<use ...> is executed at compile time B<all> C<use> 
statements will be executed B<before> script execution that can make 
unexpected results. Consider code:

  use SOAP::Lite proxy => 'http://localhost/';

  print SOAP::Lite->getStateName(1)->result;
  
  use SOAP::Lite proxy => 'http://localhost/cgi-bin/soap.cgi';

  print SOAP::Lite->getStateName(1)->result;

B<BOTH> SOAP calls will go to C<'http://localhost/cgi-bin/soap.cgi'>. If
you want to execute C<use> at run-time, put it in C<eval>:

  eval "use SOAP::Lite proxy => 'http://localhost/cgi-bin/soap.cgi'; 1" or die;

or use

  SOAP::Lite->self->proxy('http://localhost/cgi-bin/soap.cgi');

=head2 IN/OUT, OUT PARAMETERS AND AUTOBINDING

SOAP::Lite gives you access to all parameters (both in/out and out) and
also does some additional work for you. Lets consider following example:

  <mehodResponse>
    <res1>name1</res1>
    <res2>name2</res2>
    <res3>name3</res3>
  </mehodResponse>

In that case:

  $result = $r->result; # gives you 'name1'
  $paramout1 = $r->paramsout;      # gives you 'name2', because of scalar context
  $paramout1 = ($r->paramsout)[0]; # gives you 'name2' also
  $paramout2 = ($r->paramsout)[1]; # gives you 'name3'

or

  @paramsout = $r->paramsout; # gives you ARRAY of out parameters
  $paramout1 = $paramsout[0]; # gives you 'res2', same as ($r->paramsout)[0]
  $paramout2 = $paramsout[1]; # gives you 'res3', same as ($r->paramsout)[1]

Generally, if server returns C<return (1,2,3)> you will get C<1> as the result 
and C<2> and C<3> as out parameters.

If the server returns C<return [1,2,3]> you will get an ARRAY from C<result()> and 
C<undef> from C<paramsout()> .
Results can be arbitrary complex: they can be an array of something, they can
be objects, they can be anything and still be returned by C<result()> . If only
one parameter is returned, C<paramsout()> will return C<undef>.

But there is more.
If you have in your output parameters a parameter with the same
signature (name+type) as in the input parameters this parameter will be mapped
into your input automatically. Example:

B<server>:

  sub mymethod {
    shift; # object/class reference
    my $param1 = shift;
    my $param2 = SOAP::Data->name('myparam' => shift() * 2);
    return $param1, $param2;
  }

B<client>:

  $a = 10;
  $b = SOAP::Data->name('myparam' => 12);
  $result = $soap->mymethod($a, $b);

After that, C<< $result == 10 and $b->value == 24 >>! Magic? Sort of. 
Autobinding gives it to you. That will work with objects also with 
one difference: you do not need to worry about the name and the type of
object parameter. Consider the C<PingPong> example (F<examples/My/PingPong.pm> and
F<examples/pingpong.pl>):

B<server>:

  package My::PingPong;

  sub new { 
    my $self = shift;
    my $class = ref($self) || $self;
    bless {_num=>shift} => $class;
  }

  sub next {
    my $self = shift;
    $self->{_num}++;
  }

B<client>:

  use SOAP::Lite +autodispatch =>
    uri => 'urn:', 
    proxy => 'http://localhost/'
  ;

  my $p = My::PingPong->new(10); # $p->{_num} is 10 now, real object returned 
  print $p->next, "\n";          # $p->{_num} is 11 now!, object autobinded

=head2 AUTODISPATCHING AND SOAP:: PREFIX

B<WARNING>: C<autodispatch> feature can have side effects for your application 
and can affect functionality of other modules/libraries because of overloading
UNIVERSAL::AUTOLOAD. All unresolved calls will be dispatched as SOAP calls,
however it could be not what you want in some cases. If so, consider using 
object interface (see C<implementation of OO interface>). 

SOAP::Lite provides an autodispatching feature that lets you create 
code which looks the same for local and remote access.

For example:
   
  use SOAP::Lite +autodispatch =>
    uri => 'urn:/My/Examples', 
    proxy => 'http://localhost/'
  ;

tells SOAP to 'autodispatch' all calls to the 'http://localhost/' endpoint with
the 'urn:/My/Examples' uri. All consequent method calls can look like:

  print getStateName(1), "\n";
  print getStateNames(12,24,26,13), "\n";
  print getStateList([11,12,13,42])->[0], "\n";
  print getStateStruct({item1 => 10, item2 => 4})->{item2}, "\n";

As you can see, there is no SOAP specific coding at all.

The same logic will work for objects as well:

  print "Session iterator\n";
  my $p = My::SessionIterator->new(10);     
  print $p->next, "\n";  
  print $p->next, "\n";   

This will access the remote My::SessionIterator module, gets an object, and then 
calls remote methods again. The object will be transferred to the server, the 
method is executed there and the result (and the modified object!) will be 
transferred back to the client.

Autodispatch will work B<only> if you do not have the same method in your
code. For example, if you have C<use My::SessionIterator> somewhere in your
code of our previous example, all methods will be resolved locally  and no
SOAP calls will be done. If you want to get access to remote objects/methods 
even in that case, use C<SOAP::> prefix to your methods, like:

  print $p->SOAP::next, "\n";  

See C<pingpong.pl> for example of a script, that works with the same object
locally and remotely.

C<SOAP::> prefix also gives you ability to access methods that have the same
name as methods of SOAP::Lite itself. For example, you want to call method
new() for your class C<My::PingPong> through OO interface. 
First attempt could be:

  my $s = SOAP::Lite 
    -> uri('http://www.soaplite.com/My/PingPong')
    -> proxy('http://localhost/cgi-bin/soap.cgi')
  ;
  my $obj = $s->new(10);

but it won't work, because SOAP::Lite has method new() itself. To provide 
a hint, you should use C<SOAP::> prefix and call will be dispatched remotely:

  my $obj = $s->SOAP::new(10);

You can mix autodispatch and usual SOAP calls in the same code if
you need it. Keep in mind, that calls with SOAP:: prefix should always be a
method call, so if you want to call functions, use C<< SOAP->myfunction() >>
instead of C<SOAP::myfunction()>.

Be warned though Perl has very flexible syntax some versions will complain

  Bareword "autodispatch" not allowed while "strict subs" in use ...

if you try to put 'autodispatch' and '=>' on separate lines. So, keep them
on the same line, or put 'autodispatch' in quotes: 

  use SOAP::Lite 'autodispatch' # DON'T use plus in this case
    => .... 
  ; 

=head2 ACCESSING HEADERS AND ENVELOPE ON SERVER SIDE

SOAP::Lite gives you direct access to all headers and the whole envelope on 
the server side. Consider the following code from My::Parameters.pm:

  sub byname { 
    my($a, $b, $c) = @{pop->method}{qw(a b c)};
    return "a=$a, b=$b, c=$c";
  }

You will get this functionality ONLY if you inherit your class from 
the SOAP::Server::Parameters class. This should keep existing code working and
provides this feature only when you need it.

Every method on server side will be called as class/object method, so it will
get an B<object reference> or a B<class name> as the first parameter, then the 
method parameters, and then an envelope as SOAP::SOM object. Shortly:

  $self [, @parameters] , $envelope

If you have a fixed number of parameters, you can do:

  my $self = shift;
  my($param1, $param2) = @_;

and ignore the envelope. If you need access to the envelope you can do:

  my $envelope = pop; 

since the envelope is always the last element in the parameters list.
The C<byname()> method C<< pop->method >> will return a hash with
parameter names as hash keys and parameter values as hash values:

  my($a, $b, $c) = @{pop->method}{qw(a b c)};

gives you by-name access to your parameters.

=head2 SERVICE DEPLOYMENT. STATIC AND DYNAMIC

Let us scrutinize the deployment process. When designing your SOAP server you 
can consider two kind of deployment: B<static> and B<dynamic>.
For both, static and dynamic,  you should specify C<MODULE>, 
C<MODULE::method>, C<method> or C<PATH/> when creating C<use>ing the 
SOAP::Lite module. The difference between static and dynamic deployment is 
that in case of 'dynamic', any module which is not present will be loaded on
demand. See the L</"SECURITY"> section for detailed description.

Example for B<static> deployment:

  use SOAP::Transport::HTTP;
  use My::Examples;           # module is preloaded 

  SOAP::Transport::HTTP::CGI
    # deployed module should be present here or client will get 'access denied'
    -> dispatch_to('My::Examples') 
    -> handle;

Example for B<dynamic> deployment:

  use SOAP::Transport::HTTP;
  # name is unknown, module will be loaded on demand

  SOAP::Transport::HTTP::CGI
    # deployed module should be present here or client will get 'access denied'
    -> dispatch_to('/Your/Path/To/Deployed/Modules', 'My::Examples') 
    -> handle;

For static deployment you should specify the MODULE name directly. 
For dynamic deployment you can specify the name either directly (in that 
case it will be C<require>d without any restriction) or indirectly, with a PATH
In that case, the ONLY path that will be available will be the PATH given
to the dispatch_to() method). For information how to handle this situation
see L</"SECURITY"> section.

You should also use static binding when you have several different classes 
in one file and want to make them available for SOAP calls.

B<SUMMARY>: 

  dispatch_to(
    # dynamic dispatch that allows access to ALL modules in specified directory
    PATH/TO/MODULES          
    # 1. specifies directory 
    # -- AND --
    # 2. gives access to ALL modules in this directory without limits

    # static dispatch that allows access to ALL methods in particular MODULE
    MODULE 
    #  1. gives access to particular module (all available methods)
    #  PREREQUISITES:
    #    module should be loaded manually (for example with 'use ...')
    #    -- OR --
    #    you can still specify it in PATH/TO/MODULES

    # static dispatch that allows access to particular method ONLY
    MODULE::method 
    # same as MODULE, but gives access to ONLY particular method,
    # so there is not much sense to use both MODULE and MODULE::method 
    # for the same MODULE
  )

In addition to this SOAP::Lite also supports experimental syntax that
allows you bind specific URL or SOAPAction to CLASS/MODULE or object:

  dispatch_with({
    URI => MODULE,        # 'http://www.soaplite.com/' => 'My::Class',
    SOAPAction => MODULE, # 'http://www.soaplite.com/method' => 'Another::Class',
    URI => object,        # 'http://www.soaplite.com/obj' => My::Class->new,
  })

URI is checked before SOAPAction. You may use both C<dispatch_to()> and
C<dispatch_with()> syntax and C<dispatch_with()> has more priority, so
first checked URI, then SOAPAction and only then will be checked 
C<dispatch_to()>. See F<t/03-server.t> for more information and examples.

=head2 SECURITY

Due to security reasons, the current path for perl modules (C<@INC>) will be disabled
once you have chosen dynamic deployment and specified your own C<PATH/>.
If you want to access other modules in your included package you have 
several options:

=over 4

=item 1

Switch to static linking:

   use MODULE;
   $server->dispatch_to('MODULE');

It can be useful also when you want to import something specific
from the deployed modules: 

   use MODULE qw(import_list);

=item 2

Change C<use> to C<require>. The path is unavailable only during 
the initialization part, and it is available again during execution. 
So, if you do C<require> somewhere in your package, it will work.

=item 3

Same thing, but you can do: 

   eval 'use MODULE qw(import_list)'; die if $@;

=item 4

Assign a C<@INC> directory in your package and then make C<use>.
Don't forget to put C<@INC> in C<BEGIN{}> block or it won't work:

   BEGIN { @INC = qw(my_directory); use MODULE }

=back

=head2 COMPRESSION

SOAP::Lite provides you option for enabling compression on wire (for HTTP 
transport only). Both server and client should support this capability, 
but this logic should be absolutely transparent for your application. 

Compression can be enabled by specifying threshold for compression on client 
or server side:

=over 4

=item Client

  print SOAP::Lite
    -> uri('http://localhost/My/Parameters')
    -> proxy('http://localhost/', options => {compress_threshold => 10000})
    -> echo(1 x 10000)
    -> result
  ;

=item Server

  my $server = SOAP::Transport::HTTP::CGI
    -> dispatch_to('My::Parameters')
    -> options({compress_threshold => 10000})
    -> handle;

=back

For more information see L<COMPRESSION section|SOAP::Transport::HTTP/"COMPRESSION"> 
in HTTP transport documentation.

=head2 OBJECTS-BY-REFERENCE

SOAP::Lite implements an experimental (yet functional) support for
objects-by-reference. You should not see any difference on the client side 
when using this. On the server side you should specify the names of the 
classes you want to be returned by reference (instead of by value) in the 
C<objects_by_reference()> method for your server implementation (see 
soap.pop3, soap.daemon and Apache.pm).

Garbage collection is done on the server side (not earlier than after 600 
seconds of inactivity time), and you can overload the default behavior with 
specific functions for any particular class. 

Binding does not have any special syntax and is implemented on server side 
(see the differences between My::SessionIterator and My::PersistentIterator). 
On the client side, objects will have same type/class as before 
(C<< My::SessionIterator->new() >> will return an object of class 
My::SessionIterator). However, this object is just a stub with an object ID 
inside.

=head2 INTEROPERABILITY

=over 4

=item Microsoft's .NET 

To use .NET client and SOAP::Lite server

=over 4

=item qualify all elements

use fully qualified names for your return values, e.g.: 

  return SOAP::Data->name('~:myname')->type('string')->value($output);

In addition see comment about default incoding in .NET Web Services below.

=back

To use SOAP::Lite client and .NET server

=over 4

=item declare proper soapAction (uri/method) in your call

For example, use C<on_action(sub{join '', @_})>.

=item qualify all elements

Any of following actions should work:

=over 4

=item use fully qualified name for method parameters

Use C<< SOAP::Data->name('~:Query'  => 'biztalk') >> instead of 
C<< SOAP::Data->name('Query'  => 'biztalk') >>.

Example of SOAPsh call (all parameters should be in one line):

  > perl SOAPsh.pl 
    "http://beta.search.microsoft.com/search/mscomsearchservice.asmx" 
    "http://tempuri.org/" 
    "on_action(sub{join '', @_})" 
    "GetVocabulary(SOAP::Data->name('~:Query'  => 'biztalk'))"

=item make method in default namespace

instead of 

  my @rc = $soap->call(add => @parms)->result;
  # -- OR --
  my @rc = $soap->add(@parms)->result;

use

  my $method = SOAP::Data->name('add')
                         ->attr({xmlns => 'http://tempuri.org/'});
  my @rc = $soap->call($method => @parms)->result;

=item modify .NET server if you are in charge for that

Stefan Pharies <stefanph@microsoft.com>:

SOAP::Lite uses the SOAP encoding (section 5 of the soap 1.1 spec), and
the default for .NET Web Services is to use a literal encoding. So
elements in the request are unqualified, but your service expects them to 
be qualified. .Net Web Services has a way for you to change the expected 
message format, which should allow you to get your interop working. 
At the top of your class in the asmx, add this attribute:

  [SoapService(Style=SoapServiceStyle.RPC)]

Full Web Service text may look like (as far as I understand the syntax):

  <%@ WebService Language="C#" Class="Test" %>
  using System;
  using System.Web.Services;
  using System.Xml.Serialization;

  [SoapService(Style=SoapServiceStyle.RPC)]
  public class Test : WebService {
    [WebMethod] 
    public int add(int a, int b) {
      return a + b;
    }
  }

=back

=back

Thanks to 
  Petr Janata <petr.janata@i.cz>, 
  Stefan Pharies <stefanph@microsoft.com>, and 
  Brian Jepson <bjepson@jepstone.net> 
for description and examples.

=back

=head2 TROUBLESHOOTING

=over 4

=item HTTP transport

See L<TROUBLESHOOTING|SOAP::Transport::HTTP/"TROUBLESHOOTING"> section in 
documentation for HTTP transport.

=item COM interface

=over 4

=item Can't call method "server" on undefined value

Probably you didn't register Lite.dll with 'regsvr32 Lite.dll'

=item Failed to load PerlCtrl runtime

Probably you have two Perl installations in different places and
ActiveState's Perl isn't the first Perl specified in PATH. Rename the
directory with another Perl (at least during the DLL's startup) or put
ActiveState's Perl on the first place in PATH.

=back

=item XML Parsers

=over 4

=item SAX parsers

SAX 2.0 has a known bug in org.xml.sax.helpers.ParserAdapter
     rejects Namespace prefix used before declaration

(http://www.megginson.com/SAX/index.html).

That means that in some cases SOAP messages created by SOAP::Lite may not
be parsed properly by SAX2/Java parser, because Envelope
element contains namespace declarations and attributes that depends on this
declarations. According to XML specification order of these attributes is
not significant. SOAP::Lite does NOT have a problem parsing such messages.

Thanks to Steve Alpert (Steve_Alpert@idx.com) for pointing on it.

=back

=back

=head2 PERFORMANCE

=over 4

=item Processing of XML encoded fragments

SOAP::Lite is based on XML::Parser which is basically wrapper around James 
Clark's expat parser. Expat's behavior for parsing XML encoded string can 
affect processing messages that have lot of encoded entities, like XML 
fragments, encoded as strings. Providing low-level details, parser will call 
char() callback for every portion of processed stream, but individually for 
every processed entity or newline. It can lead to lot of calls and additional
memory manager expenses even for small messages. By contrast, XML messages
which are encoded as base64, don't have this problem and difference in 
processing time can be significant. For XML encoded string that has about 20 
lines and 30 tags, number of call could be about 100 instead of one for
the same string encoded as base64.

Since it is parser's feature there is NO fix for this behavior (let me know
if you find one), especially because you need to parse message you already
got (and you cannot control content of this message), however, if your are
in charge for both ends of processing you can switch encoding to base64 on
sender's side. It will definitely work with SOAP::Lite and it B<may> work with 
other toolkits/implementations also, but obviously I cannot guarantee that.

If you want to encode specific string as base64, just do 
C<< SOAP::Data->type(base64 => $string) >> either on client or on server
side. If you want change behavior for specific instance of SOAP::Lite, you 
may subclass C<SOAP::Serializer>, override C<as_string()> method that is 
responsible for string encoding (take a look into C<as_base64()>) and 
specify B<new> serializer class for your SOAP::Lite object with:

  my $soap = new SOAP::Lite
    serializer => My::Serializer->new,
    ..... other parameters

or on server side:

  my $server = new SOAP::Transport::HTTP::Daemon # or any other server
    serializer => My::Serializer->new,
    ..... other parameters

If you want to change this behavior for B<all> instances of SOAP::Lite, just
substitute C<as_string()> method with C<as_base64()> somewhere in your 
code B<after> C<use SOAP::Lite> and B<before> actual processing/sending:

  *SOAP::Serializer::as_string = \&SOAP::Serializer::as_base64;

Be warned that last two methods will affect B<all> strings and convert them
into base64 encoded. It doesn't make any difference for SOAP::Lite, but it
B<may> make a difference for other toolkits.

=back

=head2 WEBHOSTING INSTALLATION

As soon as you have telnet access to the box and XML::Parser is already
installed there you may install your own copy of SOAP::Lite even if 
hosting provider doesn't want to do it himself.

Login and setup PERL5LIB variable in your .profile (or .bash_profile):

  PERL5LIB=/you/home/directory/lib; export PERL5LIB

'lib' here is the name of directory where all libraries will be installed 
under your home directory.

Run CPAN module with

  perl -MCPAN -e shell

and run three commands

  o conf make_arg -I~/lib
  o conf make_install_arg -I~/lib
  o conf makepl_arg LIB=~/lib PREFIX=~ INSTALLMAN1DIR=~/man/man1 INSTALLMAN3DIR=~/man/man3

LIB will specify directory where all libraries will reside. 

PREFIX will specify prefix for all directoies (like lib, bin, man, but it doesn't work for all cases for some reason). 

INSTALLMAN1DIR and INSTALLMAN3DIR specify directories for man (if you don't 
specify it, install will fail because it'll try to setup it in default directory 
and you don't have permissions for that).

Now you may run:

  install SOAP::Lite

Later, in your scripts you'll need to add:

  use lib '/your/home/directory/lib';

somewhere before C<'use SOAP::Lite;'> and you're done

=head1 BUGS AND LIMITATIONS

=over 4

=item *

No support for multidimensional, partially transmitted and sparse arrays 
(however arrays of arrays are supported, as well as any other data 
structures, and you can add your own implementation with SOAP::Data). 

=item *

Limited support for WSDL schema. 

=item *

XML::Parser::Lite relies on Unicode support in Perl and doesn't do 
entity decoding. 

=item *

Limited support for mustUnderstand and Actor attributes. 

=back

=head1 PLATFORMS

=over 4

=item MacOS

Information about XML::Parser for MacPerl could be found here:
http://bumppo.net/lists/macperl-modules/1999/07/msg00047.html

Compiled XML::Parser for MacOS could be found here:
http://www.perl.com/CPAN-local/authors/id/A/AS/ASANDSTRM/XML-Parser-2.27-bin-1-MacOS.tgz

=back

=head1 AVAILABILITY

You can download the latest version SOAP::Lite for Unix or SOAP::Lite for Win32 from http://soaplite.com/ .
SOAP::Lite is available also from CPAN ( http://search.cpan.org/search?dist=SOAP-Lite ).  
You are very welcome to write mail to the author (paulclinger@yahoo.com) 
with your comments, suggestions, bug reports and complaints.

=head1 SEE ALSO

L<SOAP> SOAP/Perl library from Keith Brown ( http://www.develop.com/soap/ ) or
( http://search.cpan.org/search?dist=SOAP )

=head1 ACKNOWLEDGMENTS

A lot of thanks to
  Tony Hong <thong@xmethods.net>,
  Petr Janata <petr.janata@i.cz>,
  Murray Nesbitt <murray@ActiveState.com>,
  Robert Barta <rho@bigpond.net.au>,
  Gisle Aas <gisle@ActiveState.com>,
  Carl K. Cunningham <cc@roberts.de>,
  Graham Glass <graham-glass@mindspring.com>,
  Chris Radcliff <chris@velocigen.com>, and 
  many many others 
for provided help, feedback, support, patches and comments. 

=head1 COPYRIGHT

Copyright (C) 2000-2001 Paul Kulchenko. All rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Paul Kulchenko (paulclinger@yahoo.com)

=cut
