#!/usr/local/bin/perl -w

use strict;
use CGI;
use CGI::Carp qw(fatalsToBrowser);
use Ergatis::ConfigFile;
use HTML::Template;

my $q = new CGI;
print $q->header( -type => 'text/html' );

my $repository_root = $q->param('repository_root') || die "need a repository root";
my $component_name  = $q->param('component_name') || die "need a component name";
my $component_num;

if (defined $q->param('component_num')) {
    $component_num = $q->param('component_num');
} else {
    croak('need a component num');
}

my $shared_cfg = new Ergatis::ConfigFile( -file => "$repository_root/workflow/project.config" );
my $workflowdocs_dir = $shared_cfg->val( 'project', '$;DOCS_DIR$;' );

my $tmpl = HTML::Template->new( filename => 'templates/get_component_template.tmpl',
                                die_on_bad_params => 1,
                                global_vars => 1
                              );

my %selectable_labels = ( INPUT_FILE_LIST => 1, INPUT_FILE => 1, INPUT_DIRECTORY => 1,
                          QUERY_BSML_FILE_LIST => 1, QUERY_BSML_FILE => 1, QUERY_BSML_DIRECTORY => 1,
                          MATCH_BSML_FILE_LIST => 1, MATCH_BSML_FILE => 1, MATCH_BSML_DIRECTORY => 1, );

my $component_found = 0;
my $component_ini = "$workflowdocs_dir/${component_name}.config";
my %sections = { basic => [], advanced => [] };

## make sure the configuration exists.
if ( -e $component_ini ) {
    
    ## read this config file
    my $component_cfg = new Ergatis::ConfigFile( -file => $component_ini );
    
    ## it's possible that later the first dd could be comments and the second the value
    for my $section ( $component_cfg->Sections() ) {
        ## any sections to skip?
#        next if $section eq 'workflowdocs';
#        next if $section eq 'include';
#        next if $section eq 'component';
        my $section_type = 'basic';
        if ($section =~ /workflowdocs|include|component/) {
            $section_type = 'advanced';
        }
       
        push @{$sections{$section_type}}, { name => $section };
        
        
        for my $parameter ( $component_cfg->Parameters($section) ) {
            ## strip the parameter of the $; symbols
            my $label = $parameter;
            $label =~ s/\$\;//g;
            
            ## our variable naming 
            my $pretty_label = lc($label);
               $pretty_label =~ s/_/ /g;
            
            if ( exists $selectable_labels{$label} ) {
                push @{$sections{$section_type}->[-1]->{parameters}}, { label => $label, 
                                                        pretty_label => $pretty_label, 
                                                        value => $component_cfg->val($section, $parameter),
                                                        selectable => 1,
                                                        section => $section,
                                                        comment => $component_cfg->get_comment_html($section, $parameter) };            
            } else {
                push @{$sections{$section_type}->[-1]->{parameters}}, { label => $label, 
                                                        pretty_label => $pretty_label, 
                                                        value => $component_cfg->val($section, $parameter),
                                                        selectable => 0,
                                                        section => $section,
                                                        comment => $component_cfg->get_comment_html($section, $parameter) };
            }                
        }
    }
    
    $component_found++;
}

$tmpl->param( COMPONENT_FOUND => $component_found );
## $tmpl->param( COMPONENT_NAME    => $component_name );
$tmpl->param( BASIC_SECTIONS => $sections{basic} );
$tmpl->param( ADVANCED_SECTIONS => $sections{advanced} );
$tmpl->param( COMPONENT_NUM => $component_num );

print $tmpl->output;

exit(0);
