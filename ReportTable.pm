#
# Author: Eugenie Ivanenko
#
# Aim: report table data subclass
#
# $Id:
#


package BL::ReportTable;

use strict;

use Logging 'barf';

use XML::LibXML;
use Encode;

# rows at table data try to save directly to xml
my $NUM_ROWS_TRY_TO_XML_SAVE = 10; 
# 16kB, max size of data node
my $MAX_BYTES_TO_XML_SAVE = 1024 * 16; 

# aim: construct ReportTable object
# params: 
# parse table_node
# data_node could be undef
# db_report is Storable class for bm_report_table table
sub new {
	my $class = shift;
	my $tbl_node = shift;
	my $data_node = shift;
	my $db_report = shift;
	my $save_result_to_xml = shift;

	my $id = $tbl_node->getAttribute( 'id');
	throw BM::TemplateException( "Not found id at <table> element ". $tbl_node->line_number())
		unless $id;
	
	# Note: inner tables are possible
	# So element of fields can also be ref array for fields

    # id => table_id,
	# is_inner_tables => [0|1],
	
	my $self = bless { 
		id => $id,
		is_inner_tables => 0,
		node => $tbl_node,
		data_node => $data_node,
		db_report => $db_report,
		save_result_to_xml => $save_result_to_xml,
		fields => []
	}, 
	$class || ref $class;

	# array of table fields
    # fields => [ name_col1, name_col2, [ name_col3, fields_ref1 ],, [ name_col4, fields_ref2 ] ..., name_col100 ],
	$self->{fields} = $self->_get_fields_from_table_node( $tbl_node); 
	
	throw BM::TemplateException( "No fields defined at <table> element ". $tbl_node->line_number())
		unless @{ $self->{fields}};
	
	$self->{ is_inner_tables} = 1 if grep { ref $_ } @{ $self->{fields}};
		#if grep { UNIVERSAL::isa($_, "HASH")} @{ $self->{fields}};
		
	return $self;
}

# aim: get all fields name from data node
# calls from new()
# params: table node from xml report definition file
# return: ref to array of table fields
# note: recursive
sub _get_fields_from_table_node { 
	my $self = shift;	
	my $table_node = shift;

	throw BM::TemplateException( "Not found any child node at <". $table_node->nodeName(). "> element ". $table_node->line_number())
    	unless $table_node->hasChildNodes;
    
    my $fields = [];
	foreach my $column_node ( $table_node->childNodes) {
		if ( $column_node->nodeName eq 'column') {
			throw BM::TemplateException( "Not found id attribute at <". $column_node->nodeName. "> element ". $column_node->line_number())
				unless $column_node->getAttribute( 'id');

			push @$fields, $column_node->getAttribute('id');
		}
		elsif ( $column_node->nodeName eq 'table') {
			throw BM::TemplateException( "Not found id attribute at <". $column_node->nodeName. "> element ". $column_node->line_number())
				unless $column_node->getAttribute( 'id');
			push @$fields, [ 
				$column_node->getAttribute('id'),
				$self->_get_fields_from_table_node( $column_node)
			];
			#new BL::ReportTable( $column_node, $self->{db_report});
		}
		elsif (! $column_node->nodeName eq 'text') {
			throw BM::TemplateException( "<". $column_node->nodeName. "> child is not possible at <". $table_node->nodeName. "> ". $column_node->line_number());
		}
	}	
		
	return $fields;
}

sub id { return shift->{id} }
sub fields { return shift->{fields} }
sub is_inner_tables { return shift->{is_inner_tables} }

# add row to self->{data} stucture
# using _process row method
sub add_row {
	my $self = shift;	
	my $row = shift;
	
	$self->{data} = [] unless $self->{data};
	
	# similar to tmpl_loop structure
	push @{ $self->{data}}, $self->_process_row( $row);
	
	return 1;
}

# recursive parse row to add it to self->{data} stucture, field names are case-insensitive
sub _process_row { # recursive
	my $self = shift;	
	my $row = shift;
	my $table_fields = shift || $self->fields();
	#my $is_utf8 = shift;

	die "No row defined or not hash ref" unless $row && ref $row eq 'HASH';
	
	# case insensitive column definition
	my %row_uc = map { uc $_ => $row->{ $_} } keys %$row;
		
	# recursive add row
	my %row_fields;
	foreach my $tbl_field ( @$table_fields) {
		#my $field_uc = (ref $field_obj && UNIVERSAL::isa($field_obj, "HASH") ) ? uc $field_obj->id() : uc $field_obj;
		if ( ref $tbl_field eq "ARRAY") {
			my $field_rows = $row_uc{ uc $tbl_field->[0]};
			next unless defined $field_rows;
			die "Wrong type of field $tbl_field->[0] $field_rows" unless ref $field_rows eq 'ARRAY';
			foreach my $sub_row (@$field_rows) {
				push @{ $row_fields{ $tbl_field->[0]}}, $self->_process_row( $sub_row, $tbl_field->[1] );
			}
		}
		elsif ( defined $row_uc{ uc $tbl_field}) {
			my $row_val = $row_uc{ uc $tbl_field};
			die "Wrong type of field $tbl_field $row_val" if ref $row_val;
			$row_fields{ $tbl_field} = $row_val;
		}
		else {
			#barf "No field defined for '$tbl_field' column at $row";
		}
	}

	return \%row_fields;
}

# return $self->{data} as it is
sub data {
	my $self = shift;
	
	$self->_parse_data_node( @_) if !$self->{data} && $self->{data_node};
	#throw BM::ExecException( "Not data for current table". $table->id(). " $@") unless $self->{data};

	return $self->{data} || [];
}

# return $self->{data} as ref to array, only data with no fields (NOT RECURSIVE??)
sub data_arrayref {
	my $self = shift;
	
	$self->_parse_data_node( @_) if !$self->{data} && $self->{data_node};
	#throw BM::ExecException( "Not data for current table". $table->id(). " $@") unless $self->{data};

	my $data_arrayref = [];
	foreach my $row (@{ $self->data()}) {
		push @$data_arrayref, [ map { $row->{$_}} @{ $self->{fields}} ];
	}
	
	return $data_arrayref;
}

# synoym to data
sub data_hashref { return shift->data( @_) }

# parse data node and add data to $self->{data} structure
# using recursive _get_rows_from_data_node method
# params: data_node
# returns: OK
sub _parse_data_node { 
	my $self = shift;

	#my $data_node = shift;
	#$self->{data_node} = $data_node unless $self->{data_node};
	
	my $rows = $self->_get_rows_from_data_node( $self->{data_node}, @_);
	$self->add_row( $_) foreach @$rows;
	
	return 1;
}

# parse data node
# if data stored at db (ref atributes) calls BM::Report->get_table_data method 
# params: data_node
# return: ref to rows
# note: recursive
sub _get_rows_from_data_node { 
	my $self = shift;
	my $data_node = shift;
	my $start_row = shift; # used only for root table
	my $stop_row = shift;  # used only for root table

	my $rows = [];
	if ( $data_node->getAttribute( 'stored_at_db')) {
		return $self->{db_report}->get_table_data( $self, $start_row, $stop_row); # page is 0, all data
	}
	else {
		my @row_nodes = $data_node->findnodes( 'child::row');
		@row_nodes = @row_nodes[$start_row..$stop_row] if (defined $start_row && defined $stop_row);
		
		foreach my $row_node (@row_nodes) {
			my @column_nodes = $row_node->findnodes( 'child::column | child::data');
			my %row;
			foreach my $column (@column_nodes) {
				if ( $column->nodeName eq 'column') {
					$row{ $column->getAttribute( 'id')} = $column->textContent();
				}
				elsif ( $column->nodeName eq 'data') {	
					$row{ $column->getAttribute( 'id')} = $self->_get_rows_from_data_node( $column);
				}
			}
			push @$rows, \%row;
		}
	}

	return $rows;
}

sub save_data {
	my $self = shift;
	
	unless ( $self->{data}) {
		barf "No data to save at table '".$self->id()."'";
	
		my $data_node = new XML::LibXML::Element( 'data');
	    $data_node->setAttribute( 'id', $self->id());
	    $data_node->setAttribute( 'rows', 0);

		return $data_node;
	}
	
	# check the save_result_to_xml flag
	if (scalar @{ $self->{data}} < $NUM_ROWS_TRY_TO_XML_SAVE || $self->{save_result_to_xml} ) {
		# build xml for table data
		my $data_node = $self->as_xml();
		# check size of table
		if ( length $data_node->toString() <= $MAX_BYTES_TO_XML_SAVE) { 
			barf "Saving as xml, table '". $self->id."'";
			return $data_node;
		}
		# save to db
		else {
			barf "Saving to bm_report_table, table '".$self->id."'";
			return $self->save_data_to_db();
		}
	}
	# save to db
	else {
		barf "Saving to bm_report_table, table '".$self->id."'";
		return $self->save_data_to_db();
	}
}

# return $self->{data} structure as xml object
# using _get_data_node method
sub as_xml { 
	my $self = shift;
	
	# cashed
	return $self->{as_xml} if $self->{as_xml};

	$self->{as_xml} = $self->_get_data_node();
	return $self->{as_xml}
}  

# construct data node xml from $self->{data} structure
# params: data, table_id, fields, tab_shift
# return: data_node
# note: recursive
sub _get_data_node { 
	my $self = shift;
	my $id = shift || $self->{id};
	my $fields = shift || $self->fields();
	my $data = shift || $self->{data} || [];
	my $tab_shift = shift || "";
	
	my $data_node = new XML::LibXML::Element( 'data');
    $data_node->setAttribute( 'id', $id );
    $data_node->setAttribute( 'rows', scalar @$data );
    
   	foreach my $row ( @$data) {
   		my $row_node = new XML::LibXML::Element( 'row');
		foreach my $field ( @$fields) {
			my $column_node;
			if ( ref $field eq 'ARRAY') {
				next unless defined $row->{$field->[0]};
				$column_node = $self->_get_data_node(  $field->[0], $field->[1], $row->{$field->[0]}, $tab_shift. "\t\t");
				die "Can't return data as xml for table '". $field->[0]."'" unless $column_node;
			}
			else {
				next unless defined $row->{$field};
	
				my $row_val = $row->{$field};
			 	die "Types of field $field and data $row_val result are different"
			 		if ref $row_val;
			 	
				$column_node = new XML::LibXML::Element( 'column');
				$column_node->setAttribute( 'id', $field);
				$column_node->appendText( Encode::encode( 'utf8', $row_val));
			}
			
			$row_node->addChild( XML::LibXML::Text->new( "\n". $tab_shift. "\t\t"));
			$row_node->addChild( $column_node);
   		}
		$data_node->addChild( XML::LibXML::Text->new( "\n". $tab_shift. "\t"));
		$data_node->addChild( $row_node);
	}
    
	return $data_node;
}

# save table data to db 
# return xml tag with ref to db
sub save_data_to_db {
	my $self = shift;	

	#throw BM::ExecException "Table not saved at db " unless $self->{stored_at_db};

	$self->{stored_at_db} = $self->{db_report}->save_table_data( $self);

	my $data_node = new XML::LibXML::Element( 'data');
    $data_node->setAttribute( 'id', $self->id());
    $data_node->setAttribute( 'stored_at_db', $self->{stored_at_db});
    $data_node->setAttribute( 'rows', scalar @{ $self->data()});

	return $data_node;	
}

# return id from bm_report_table table
sub stored_at_db_id { return shift->{data_node}->getAttribute( 'stored_at_db') }

# return quantity of rows saved at bm_report_table, useful for page navigation
sub num_rows { return shift->{data_node}->getAttribute( 'rows') }

1;
