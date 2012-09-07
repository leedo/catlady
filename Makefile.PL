use inc::Module::Install;
name 'Catlady';
perl_version '5.008';
author 'Lee Aylward <leedo@cpan.org>';
all_from 'lib/Catlady.pm';
license 'perl';

requires 'DBD::SQLite';
requires 'Digest::SHA1';
requires 'Plack::Middleware::ReverseProxy';
requires 'Plack::Session';
requires 'AnyEvent::DBI::Abstract';
requires 'Path::Class';

WriteAll;
