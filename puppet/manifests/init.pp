case $operatingsystem {
  /^(Debian|Ubuntu)$/ : { 
    $libxml = 'libxml2-dev'
    $libxslt = 'libxslt1-dev'
    $zlib = 'zlib1g-dev'
    $supervisor_service = 'supervisor'
    $supervisor_config = '/etc/supervisor/supervisord.conf'
    $pkgs = [ 'git', 'supervisor', 'build-essential', $libxml, $libxslt, $zlib, 'sqlite3' ] 
  }
  'RedHat', 'CentOS'  : {
    $libxml = 'libxml2-devel'
    $libxslt = 'libxslt-devel'
    $zlib = 'zlib-devel'
    $supervisor_service = 'supervisord'
    $supervisor_config = '/etc/supervisord.conf'
    $pkgs = [ 'git', 'supervisor', $libxml, $libxslt, $zlib, 'epel-release' ] 
  }
}
$user = 'vagrant'
$group = 'vagrant'
$dir = '/opt/readthedocs'
$venv = "$dir/venv"
$vbin = "$venv/bin/:/usr/bin/:/bin/"
$checkouts = "$dir/checkouts"
$working_dir = "$checkouts/readthedocs"
$port = 8000
$supervisor_port = 9001

if $operatingsystem =~ /^(Debian|Ubuntu)$/ {
  exec { 'apt-get update' :
    path => '/usr/bin/',
  }

  Package {
    allow_virtual => false,
    require => Exec['apt-get update'],
  }
} else {
  Package {
    allow_virtual => false,
  }
}

File {
  owner => $user,
  group => $group,
}

user { $user :
  ensure => present
}

package { $pkgs :
  ensure => installed,
}

ssh_keygen { $user :
  comment => 'vagrant@readthedocs',
} ->
file { '/vagrant/id_rsa.pub' :
  ensure => present,
  source => "/home/$user/.ssh/id_rsa.pub",
}

case $operatingsystem {
  /^(Debian|Ubuntu)$/ : { 
    class { 'python' :
      version    => 'system',
      pip        => true,
      dev        => true,
      virtualenv => true,
      require    => Package['sqlite3'],  # a workaround, ubuntu only - rtd::database requires it
    } 
  }
  'RedHat', 'CentOS'  : { 
    class { 'python' :
      version    => 'system',
      pip        => true,
      dev        => true,
      virtualenv => true,
      require    => Package['epel-release'],
    } 
  }
}

file { [$dir, $checkouts] :
  ensure => directory,
  before => Vcsrepo['rtd'],
}

vcsrepo { 'rtd' :
  ensure   => present,
  owner    => $user,
  group    => $group,
  path     => $checkouts,
  provider => git,
  source   => 'https://github.com/rtfd/readthedocs.org.git',
  require  => Package['git'],
}

file { "$working_dir/settings/local_settings.py" :
  ensure  => present,
  content => 'ALLOW_PRIVATE_REPOS = True',
  require => Vcsrepo['rtd'],
}

python::virtualenv { $venv :
  owner        => $user,
  group        => $group,
  requirements => "$checkouts/requirements.txt",
  timeout      => 3600,
  require      => [ 
    Vcsrepo['rtd'], 
    Package[$libxml], 
    Package[$libxslt], 
    Package[$zlib]
  ],
}

rtd::database { 'prepare' :
  dir     => $working_dir,
  user    => $user,
  path    => $vbin,
  clean   => false,
  require => Python::Virtualenv[$venv],
}

file { $supervisor_config :
  ensure  => file,
  mode    => '0644',
  owner   => 'root',
  group   => 'root',
  content => template('supervisor/supervisord.conf.erb'),
  require => [ Rtd::Database['prepare'], Package['supervisor'] ],
} ~>
service { $supervisor_service :
  ensure => running,
  enable => true,
}

# firewall
case $operatingsystem {
  'RedHat', 'CentOS': {
    # I do not deny...
    Firewalld_rich_rule {
      ensure => present,
      zone   => 'public',
      action => 'accept',
    }

    firewalld_rich_rule { 'allow rtd access in public zone':
      port => {
        'port'     => $port,
        'protocol' => 'tcp',
      },
    }

    firewalld_rich_rule { 'allow supervisord access in public zone':
      port => {
        'port'     => $supervisor_port,
        'protocol' => 'tcp',
      },
    }
  }

  default: {
    include effing_firewall

    firewall { "010 accept tcp access" :
      port     => [ $port, $supervisor_port ],
      proto    => tcp,
      action   => accept,
    }
  }
}