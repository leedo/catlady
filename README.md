Create a new database using the provided SQL:

<pre>
  sqlite3 catlady.db &lt; catlady.sqlite.sql
</pre>

Setup catlady:

<pre>
  git clone https://github.com/leedo/catlady.git
  cd catlady
  git submodule init
  git submodule update
  sudo apt-get install cpanminus libmodule-install-perl libssl1.0.0 libdbi-perl libev-perl
  cpanm -Snq --installdeps .
  cpanm -Snq --installdeps ./alice
  mkdir users
  cp config.example.js config.json
  vim config.json
</pre>

Add a user:

<pre>
  ./bin/manage adduser &lt;username&gt; &lt;password&gt;
</pre>

Run the catlady:

<pre>
  perl -Ilib -Ialice/lib bin/catlady config.json
</pre>

Any templates from `alice/share/templates` can be overridden copying to
`templates`. This can be useful for making your own dropdown menu items
or login screen.
