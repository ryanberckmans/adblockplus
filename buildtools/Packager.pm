package Packager;

use strict;
use warnings;

sub new
{
  my ($class, $params) = @_;

  unless (exists($params->{build}))
  {
    $params->{build} = `hg id -i`;
    $params->{build} =~ s/\W//gs;
  }

  my $self = bless($params, $class);

  return $self;
}

sub readVersion
{
  my ($self, $versionFile) = @_;

  open(local *FILE, $versionFile) or die "Could not open version file $versionFile";
  $self->{version} = <FILE>;
  $self->{version} =~ s/[^\w\.]//gs;
  if (exists $self->{devbuild})
  {
    unless ($self->{version} =~ /\D$/)
    {
      $self->{version} .= ".0" while ($self->{version} =~ tr/././ < 2);
      $self->{version} .= "+";
    }
    $self->{version} .= "." . $self->{devbuild};
  }
  close(FILE);
}

sub readBasename
{
  my ($self, $manifestFile) = @_;

  my $data = $self->readFile($manifestFile);
  die "Could not open manifest file $manifestFile" unless defined $data;
  die "Could not find JAR file name in $manifestFile" unless $data =~ /\bjar:chrome\/(\S+?)\.jar\b/;

  $self->{baseName} = $1;
}

sub readLocales
{
  my ($self, $localesDir, $includeIncomplete) = @_;

  opendir(local *DIR, $localesDir) or die "Could not open locales directory $localesDir";
  my @locales = grep {!/[^\w\-]/ && ($includeIncomplete || !-e("$localesDir/$_/.incomplete"))} readdir(DIR);
  closedir(DIR);
  
  @locales = sort {$a eq "en-US" ? -1 : ($b eq "en-US" ? 1 : $a cmp $b)} @locales;

  $self->{locales} = \@locales;
}

sub readLocaleData
{
  my ($self, $localesDir) = @_;

  $self->{localeData} = {};
  $self->{name} = '';
  $self->{description} = '';
  $self->{homepage} = '';

  foreach my $locale (@{$self->{locales}})
  {
    my $data = $self->readFile("$localesDir/$locale/meta.properties");
    next unless defined $data;

    $self->{localeData}{$locale} = {id => $locale};
    while ($data =~ /^\s*(?![!#])(\S+)\s*=\s*(.+)$/mg)
    {
      if ($1 eq "name" || $1 eq "description" || $1 eq "homepage" || $1 eq "translator" || $1 eq "description.short" || $1 eq "description.long")
      {
        $self->{localeData}{$locale}{$1} = $2;
      }
    }
  }

  if (exists($self->{localeData}{"en-US"}))
  {
    $self->{name} = $self->{localeData}{"en-US"}{name} if exists($self->{localeData}{"en-US"}{name});
    $self->{description} = $self->{localeData}{"en-US"}{description} if exists($self->{localeData}{"en-US"}{description});
    $self->{homepage} = $self->{localeData}{"en-US"}{homepage} if exists($self->{localeData}{"en-US"}{homepage});
  }

  my $info = "";
  my %translators = ();
  foreach my $locale (sort {$a->{id} cmp $b->{id}} values %{$self->{localeData}})
  {
    if (exists($locale->{translator}))
    {
      foreach my $translator (split(/,/, $locale->{translator}))
      {
        $translator =~ s/^\s+//g;
        $translator =~ s/\s+$//g;
        $translators{$translator} = 1 if $translator ne "";
      }
    }
    $locale->{name} = $self->{name} unless exists($locale->{name}) && $locale->{name} && $locale->{name} ne $self->{name};
    $locale->{description} = $self->{description} unless exists($locale->{description}) && $locale->{description} && $locale->{description} ne $self->{description};
    $locale->{homepage} = $self->{homepage} unless exists($locale->{homepage}) && $locale->{homepage} && $locale->{homepage} ne $self->{homepage};

    my $id = $self->encodeXML($locale->{id});
    my $name = $self->encodeXML($locale->{name});
    my $description = $self->encodeXML($locale->{description});
    my $homepage = $self->encodeXML($locale->{homepage});

    $info .= <<EOT;
\t<em:localized>
\t\t<Description>
\t\t\t<em:locale>$id</em:locale>
\t\t\t<em:name>$name</em:name>
\t\t\t<em:description>$description</em:description>
\t\t\t<em:homepageURL>$homepage</em:homepageURL>
\t\t</Description>
\t</em:localized>
EOT
  }

  $info .= "\n";

  foreach my $translator (sort keys %translators)
  {
    $translator = $self->encodeXML($translator);
    $info .= <<EOT;
\t<em:translator>$translator</em:translator>
EOT
  }

  $self->{localizedInfo} = $info;
}

sub readNameFromManifest
{
  my ($self, $installManifestFile) = @_;

  my $installRDF = $self->readFile($installManifestFile);
  return unless $installRDF;

  $installRDF =~ s/<em:(requires|targetApplication)>.*?<\/em:\1>//gs;

  $self->{name} = $1 if $installRDF =~ /<em:name>\s*([^<>]+?)\s*<\/em:name>/;
}

sub rm_rec
{
  my ($self, $dir) = @_;

  opendir(local *DIR, $dir) or return;
  foreach my $file (readdir(DIR))
  {
    if ($file =~ /[^.]/)
    {
      if (-d "$dir/$file")
      {
        $self->rm_rec("$dir/$file");
      }
      else
      {
        unlink("$dir/$file");
      }
    }
  }
  closedir(DIR);

  rmdir($dir);
}

sub cp
{
  my ($self, $fromFile, $toFile, $exclude) = @_;

  if ($exclude)
  {
    foreach my $file (@$exclude)
    {
      return if index($fromFile, $file) >= 0;
    }
  }

  my $textMode = ($fromFile =~ /\.(manifest|xul|jsm?|xml|xhtml|rdf|dtd|properties|css)$/);
  my $extendedTextMode = ($fromFile =~ /\.(?:jsm?|rdf|manifest)$/);

  open(local *FROM, $fromFile) or return;
  open(local *TO, ">$toFile") or return;
  binmode(TO);
  if ($textMode)
  {
    print TO map {
      s/\r//g;
      s/^((?:  )+)/"\t" x (length($1)\/2)/e;
      s/\{\{VERSION\}\}/$self->{version}/g if $extendedTextMode;
      s/\{\{BUILD\}\}/$self->{build}/g if $extendedTextMode;
      s/\{\{NAME\}\}/$self->{name}/g if $extendedTextMode;
      s/\{\{DESCRIPTION\}\}/$self->{description}/g if $extendedTextMode;
      s/\{\{HOMEPAGE\}\}/$self->{homepage}/g if $extendedTextMode;
      s/\{\{LOCALIZED\}\}/$self->{localizedInfo}/g if $extendedTextMode;
      if ($extendedTextMode && /\{\{LOCALE\}\}/)
      {
        my $loc = "";
        for my $locale (@{$self->{locales}})
        {
          my $tmp = $_;
          $tmp =~ s/\{\{LOCALE\}\}/$locale/g;
          $loc .= $tmp;
        }
        $_ = $loc;
      }

      if ($self->{devbuild} && $fromFile =~ /\binstall\.rdf$/ && /^(\s*)<em:version>/)
      {
        $_ .= "$1<em:updateURL><![CDATA[https://adblockplus.org/devbuilds/update.rdf?reqVersion=%REQ_VERSION%&id=%ITEM_ID%&version=%ITEM_VERSION%&maxAppVersion=%ITEM_MAXAPPVERSION%&status=%ITEM_STATUS%&appID=%APP_ID%&appVersion=%APP_VERSION%&appOS=%APP_OS%&appABI=%APP_ABI%&locale=%APP_LOCALE%&currentAppVersion=%CURRENT_APP_VERSION%&updateType=%UPDATE_TYPE%]]></em:updateURL>\n";
      }

      $_ = $self->{postprocess_line}->($fromFile, $_) if exists $self->{postprocess_line};

      $_;
    } <FROM>;
  }
  else
  {
    local $/;
    binmode(FROM);
    print TO <FROM>;
  }

  $self->{postprocess_file}->($fromFile, *TO) if exists $self->{postprocess_file};

  close(TO);
  close(FROM);
}

sub cp_rec
{
  my ($self, $fromDir, $toDir, $exclude) = @_;

  if ($exclude)
  {
    foreach my $file (@$exclude)
    {
      return if index($fromDir, $file) >= 0;
    }
  }

  my @files;
  if ($fromDir =~ /\blocale$/ && exists $self->{locales})
  {
    @files = @{$self->{locales}};
  }
  else
  {
    opendir(local *DIR, $fromDir) or return;
    @files = readdir(DIR);
    closedir(DIR);
  }

  $self->rm_rec($toDir);
  mkdir($toDir);
  foreach my $file (@files)
  {
    if ($file =~ /[^.]/)
    {
      if (-d "$fromDir/$file")
      {
        $self->cp_rec("$fromDir/$file", "$toDir/$file", $exclude);
      }
      else
      {
        $self->cp("$fromDir/$file", "$toDir/$file", $exclude);
      }
    }
  }
}

sub encodeXML
{
  my ($self, $str) = @_;
  $str =~ s/&/&amp;/g;
  $str =~ s/</&lt;/g;
  $str =~ s/>/&gt;/g;
  $str =~ s/"/&quot;/g; #"
  return $str;
}

sub createFileDir
{
  my ($self, $fileName) = @_;

  my @parts = split(/\/+/, $fileName);
  pop @parts;

  my $dir = '.';
  foreach my $part (@parts)
  {
    $dir .= '/' . $part;
    mkdir($dir);
  }
}

sub fixZipPermissions
{
  my ($self, $fileName) = @_;
  my $invalid = 0;
  my($buf, $entries, $dirlength);

  open(local *FILE, "+<", $fileName) or ($invalid = 1);
  unless ($invalid)
  {
    seek(FILE, -22, 2);
    sysread(FILE, $buf, 22);
    (my $signature, $entries, $dirlength) = unpack("Vx6vVx6", $buf);
    if ($signature != 0x06054b50)
    {
      print STDERR "Wrong end of central dir signature!\n";
      $invalid = 1;
    }
  }
  unless ($invalid)
  {
    seek(FILE, -22-$dirlength, 2);
    for (my $i = 0; $i < $entries; $i++)
    {
      sysread(FILE, $buf, 46);
      my ($signature, $namelen, $attributes) = unpack("Vx24vx8V", $buf);
      if ($signature != 0x02014b50)
      {
        print STDERR "Wrong central file header signature!\n";
        $invalid = 1;
        last;
      }
      my $attr_high = $attributes >> 16;
      $attr_high = ($attr_high & ~0777) | ($attr_high & 040000 ? 0755 : 0644);
      $attributes = ($attributes & 0xFFFF) | ($attr_high << 16);
      seek(FILE, -8, 1);
      syswrite(FILE, pack("V", $attributes));
      seek(FILE, 4 + $namelen, 1);
    }
  }
  close(FILE);

  unlink $fileName if $invalid;
}

sub makeJAR
{
  my ($self, $jarFile, @files) = @_;

  $self->rm_rec('tmp');
  unlink($jarFile);

  mkdir('tmp');

  my @include = ();
  my @exclude = ();
  foreach my $file (@files)
  {
    if ($file =~ s/^-//)
    {
      push @exclude, $file;
    }
    else
    {
      push @include, $file;
    }
  }

  foreach my $file (@include)
  {
    if (-d $file)
    {
      $self->cp_rec($file, "tmp/$file", \@exclude);
    }
    else
    {
      $self->cp($file, "tmp/$file", \@exclude);
    }
  }

  chdir('tmp');
  $self->fixLocales();
  system('zip', '-rqXD0', $jarFile, @include);
  chdir('..');

  rename("tmp/$jarFile", "$jarFile");
  
  $self->rm_rec('tmp');
}

sub fixLocales()
{
  my $self = shift;

  # Add missing files
  opendir(local *DIR, "locale/en-US") or return;
  foreach my $file (readdir(DIR))
  {
    next if $file =~ /^\./;

    foreach my $locale (@{$self->{locales}})
    {
      next if $locale eq "en-US";

      if (-f "locale/$locale/$file")
      {
        if ($file =~ /\.dtd$/)
        {
          $self->fixDTDFile("locale/$locale/$file", "locale/en-US/$file");
        }
        elsif ($file =~ /\.properties$/)
        {
          $self->fixPropertiesFile("locale/$locale/$file", "locale/en-US/$file");
        }
      }
      else
      {
        $self->cp("locale/en-US/$file", "locale/$locale/$file");
      }
    }
  }
  closedir(DIR);

  # Remove extra files
  foreach my $locale (@{$self->{locales}})
  {
    next if $locale eq "en-US";

    opendir(local *DIR, "locale/$locale") or next;
    foreach my $file (readdir(DIR))
    {
      next if $file =~ /^\./;

      unlink("locale/$locale/$file") unless -f "locale/en-US/$file";
    }
    closedir(DIR);
  }
}

my $S = qr/[\x20\x09\x0D\x0A]/;
my $Name = qr/[A-Za-z_:][\w.\-:]*/;
my $Reference = qr/&$Name;|&#\d+;|&#x[\da-fA-F]+;/;
my $PEReference = qr/%$Name;/;
my $EntityValue = qr/"(?:[^%&"]|$PEReference|$Reference)*"|'(?:[^%&']|$PEReference|$Reference)*'/;

sub fixDTDFile
{
  my ($self, $file, $referenceFile) = @_;

  my $data = $self->readFile($file);
  my $reference = $self->readFile($referenceFile);

  my $changed = 0;
  $data .= "\n" unless $data =~ /\n$/s;
  while ($reference =~ /<!ENTITY$S+($Name)$S+$EntityValue$S*>/gs)
  {
    my ($match, $name) = ($&, $1);
    unless ($data =~ /<!ENTITY$S+$name$S+$EntityValue$S*>/s)
    {
      $data .= "$match\n";
      $changed = 1;
    }
  }

  $self->writeFile($file, $data) if $changed;
}

sub fixPropertiesFile
{
  my ($self, $file, $referenceFile) = @_;

  my $data = $self->readFile($file);
  my $reference = $self->readFile($referenceFile);

  my $changed = 0;
  $data .= "\n" unless $data =~ /\n$/s;
  while ($reference =~ /^\s*(?![!#])(\S+)\s*=\s*.+$/mg)
  {
    my ($match, $name) = ($&, $1);
    unless ($data =~ /^\s*(?![!#])($name)\s*=\s*.+$/m)
    {
      $data .= "$match\n";
      $changed = 1;
    }
  }

  $self->writeFile($file, $data) if $changed;
}

sub readFile
{
  my ($self, $file) = @_;

  open(local *FILE, "<", $file) || return undef;
  binmode(FILE);
  local $/;
  my $result = <FILE>;
  close(FILE);

  return $result;
}

sub writeFile
{
  my ($self, $file, $contents) = @_;

  open(local *FILE, ">", $file) || return;
  binmode(FILE);
  print FILE $contents;
  close(FILE);
}

sub makeXPI
{
  my ($self, $xpiFile, @files) = @_;

  $self->rm_rec('tmp');
  unlink($xpiFile);

  mkdir('tmp');

  foreach my $file (@files)
  {
    if (-d $file)
    {
      $self->cp_rec($file, "tmp/$file");
    }
    else
    {
      $self->createFileDir("tmp/$file");
      $self->cp($file, "tmp/$file");
    }
  }

  if (-f '.signature')
  {
    my $signData = $self->readFile(".signature");
    my ($signtool) = ($signData =~ /^signtool=(.*)/mi);
    my ($certname) = ($signData =~ /^certname=(.*)/mi);
    my ($dbdir) = ($signData =~ /^dbdir=(.*)/mi);
    my ($dbpass) = ($signData =~ /^dbpass=(.*)/mi);

    system($signtool, '-k', $certname, '-d', $dbdir, '-p', $dbpass, 'tmp');

    # Add signature files to list and make sure zigbert.rsa is always compressed first
    opendir(local *METADIR, 'tmp/META-INF');
    unshift @files, map {"META-INF/$_"} sort {
      my $aValue = ($a eq 'zigbert.rsa' ? -1 : 0);
      my $bValue = ($b eq 'zigbert.rsa' ? -1 : 0);
      $aValue <=> $bValue;
    } grep {!/^\./} readdir(METADIR);
    closedir(METADIR);
  }

  chdir('tmp');
  system('zip', '-rqDX9', '../temp_xpi_file.xpi', @files);
  chdir('..');

  $self->fixZipPermissions("temp_xpi_file.xpi") if $^O =~ /Win32/i;
  
  rename("temp_xpi_file.xpi", $xpiFile);

  $self->rm_rec('tmp');
}

1;
