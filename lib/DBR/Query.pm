# the contents of this file are Copyright (c) 2004-2009 Daniel Norman
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation.

package DBR::Query;

use strict;
use base 'DBR::Common';

use DBR::Query::ResultSet::DB;

sub new {
      my( $package ) = shift;
      my %params = @_;

      my $self = {
		  instance => $params{instance},
		  session  => $params{session},
		  scope    => $params{scope},
		 };

      bless( $self, $package );

      $self->{instance} || croak "instance is required";

      $self->{flags} = {
			lock    => $params{lock} ? 1:0,
		       };

      if ($params{limit}){
 	    return $self->_error('invalid limit') unless $params{limit} =~ /^\d+$/;
	    $self->{limit} = $params{limit};
      }

      $self->select ( $params{select} );
      $self->insert ( $params{insert} );
      $self->update ( $params{update} );
      $self->delete ( $params{delete} ? 1 : 0 );
      $self->count  ( $params{count}  ? 1 : 0 );
      $self->tables ( $params{tables} );
      $self->where  ( $params{where}  );

      return( $self );
}

sub select{
  my $self = shift;
  exists( $_[0] ) or return $self->{select} || undef;
  my $part = shift;

  !$part || ref($part) eq 'DBR::Query::Part::Select' || croak "Select must be an ::Part::Select object";
  $self->{select} = $part || undef;
}

sub insert{
  my $self = shift;
  exists( $_[0] ) or return $self->{insert} || undef;
  my $part = shift;

  !$part || ref($part) eq 'DBR::Query::Part::Insert' || croak "Insert must be an ::Part::Insert object";
  $self->{insert} = $part || undef;
}

sub update{
  my $self = shift;
  exists( $_[0] )  or return $self->{update} || undef;
  my $part = shift;

  !$part || ref($part) eq 'DBR::Query::Part::Update' || croak "Update must be a ::Part::Update object";
  $self->{update} = $part || undef;
}
#delete
#count

sub tables{
      my $self   = shift;
      my $tables = shift;

      $tables = [$tables] unless ref($tables) eq 'ARRAY';
      return $self->_error('At least one table must be specified') unless @$tables;

      my @tparts;
      my %aliasmap;
      foreach my $table (@$tables){
	    return $self->_error('must specify table as a DBR::Config::Table object') unless ref($table) =~ /^DBR::Config::Table/; # Could also be ::Anon

	    my $name  = $table->name or return $self->_error('failed to get table name');
	    my $alias = $table->alias;
	    $aliasmap{$alias} = $name if $alias;

	    push @tparts, $table->sql;
      }

      $self->{tparts}   = \@tparts;
      $self->{aliasmap} = \%aliasmap;

      return 1;
}


sub where{
      my $self = shift;
      exists( $_[0] )  or return $self->{where} || undef;
      my $part = shift;

      !$part || ref($part) =~ /^DBR::Query::Part::(And|Or|Compare|Subquery|Join)$/ ||
	croak('param must be an AND/OR/COMPARE/SUBQUERY/JOIN object');

      $self->{where} = $part || undef;
}

sub scope { $_[0]->{scope} }

sub check_table{
      my $self  = shift;
      my $alias = shift;

      return $self->{aliasmap}->{$alias} ? 1 : 0;
}

sub sql{
      my $self = shift;

      return $self->{sql} if exists($self->{sql});

      my $sql;

      my $tables = join(',',@{$self->{tparts}});
      my $type = $self->{type};

      if ($self->{select}){
	    $sql .= "SELECT " . $self->{select}->sql . "FROM $tables";
	    $sql .= " WHERE " . $self->{where} ->sql if $self->{where};
      }elsif($self->{insert}){
	    $sql .= "INSERT INTO $tables " . $self->{main_sql};
      }elsif($type eq 'update'){
	    $sql .= "UPDATE $tables SET $self->{main_sql} WHERE $self->{where_sql}";
      }elsif($type eq 'delete'){
	    $sql .= "DELETE FROM $tables WHERE $self->{where_sql}";
      }

      $sql .= ' FOR UPDATE'           if $self->{flags}->{lock};
      $sql .= " LIMIT $self->{limit}" if $self->{limit};

      $self->{sql} = $sql;

      return $sql;
}

sub can_be_subquery {
      my $self = shift;
      my $select = $self->{select} || return 0;   # must be a select
      return scalar($select->fields) == 1 || 0; # and have exactly one field
}

sub validate{
      #$part->validate($self) or return $self->_error('Where clause validation failed');
}
sub prepare {
      my $self = shift;

      #       if($params->{quiet_error}){
      # 	    $self->{quiet_error} = 1;
      #       }

      return $self->_error('can only call resultset on a select') unless $self->{type} eq 'select';

      my $conn   = $self->{instance}->connect('conn') or return $self->_error('failed to connect');

      my $sql = $self->sql;

      $self->_logDebug2( $sql );

      return $self->_error('failed to prepare statement') unless
	my $sth = $conn->prepare($sql);

      return $sth;

}


sub resultset{
      my $self = shift;

      return $self->_error('can only call resultset on a select') unless $self->{type} eq 'select';

      my $resultset = DBR::Query::ResultSet::DB->new(
						     session   => $self->{session},
						     query    => $self,
						     #instance => $self->{instance},
						    ) or return $self->_error('Failed to create resultset');

      return $resultset;

}

sub is_count{
      my $self = shift;
      return $self->{flags}->{is_count} || 0,
}

sub execute{
      my $self = shift;
      my %params = @_;

      $self->_logDebug2( $self->sql );

      my $conn   = $self->{instance}->connect('conn') or return $self->_error('failed to connect');

      $conn->quiet_next_error if $self->{quiet_error};

      if($self->{type} eq 'insert'){

	    $conn->prepSequence() or return $self->_error('Failed to prepare sequence');

	    my $rows = $conn->do($self->sql) or return $self->_error("Insert failed");

	    # Tiny optimization: if we are being executed in a void context, then we
	    # don't care about the sequence value. save the round trip and reduce latency.
	    return 1 if $params{void};

	    my ($sequenceval) = $conn->getSequenceValue();
	    return $sequenceval;

      }elsif($self->{type} eq 'update'){

	    my $rows = $conn->do($self->sql);

	    return $rows || 0;

      }elsif($self->{type} eq 'delete'){

	    my $rows = $conn->do($self->sql);

	    return $rows || 0;

      }elsif($self->{type} eq 'select'){
	    return $self->_error('cannot call execute on a select');
      }

      return $self->_error('unknown query type')
}

sub makerecord{
      my $self = shift;
      my %params = @_;
      return $self->_error('rowcache is required') unless $params{rowcache};

      $self->_stopwatch();

      my $handle = DBR::Query::RecMaker->new(
					     instance => $self->{instance},
					     session  => $self->{session},
					     query    => $self,
					     rowcache => $params{rowcache},
					    ) or return $self->_error('failed to create record class');

      # need to keep this in scope, because it removes the dynamic class when DESTROY is called
      $self->_stopwatch('recmaker');

      return $handle;

}


1;
