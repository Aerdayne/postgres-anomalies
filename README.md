# Postgres Anomalies

This is a casual test suite that displays common anomalies possible at each isolation level in Postgres, as well as ways to avoid them. It is meant to be a companion repository to [this article](https://dansvetlov.me/postgres-anomalies/).

The suite is written in Ruby with ActiveRecord as an ORM and RSpec as the testing framework. It is located in the [`spec/vignettes`](./spec/vignettes/) directory and is separated into multiple subdirectories, each dedicated to a specific isolation level, where each spec file represents a particular situation that shows the possibility or impossibility of an anomaly.

Next to each file containing the source code is a log file containing the generated SQL code formatted and tagged in such a way that the order of operations is clear.

Shortcuts:
- [Atomicity](./spec/vignettes/atomicity/)
- [Read Committed isolation level](./spec/vignettes/isolation_read_committed/)
- [Repeatable Read isolation level](./spec/vignettes/isolation_repeatable_read/)
- [Serializable isolation level](./spec/vignettes/isolation_serializable/)

Use the [article](https://dansvetlov.me/postgres-anomalies/) as a cohesive narrative for best experience.

## Running the Suite

Start docker-compose with a Postgres server:

```shell
docker-compose -f test.docker-compose.yml -p postgres_anomalies_test up
```

The suite can then be run using a local Ruby installation via:

```shell
bundle exec rspec
```

Alternatively, the suite can be run from within the container:

```shell
docker-compose -f test.docker-compose.yml -p postgres_anomalies_test run postgres-anomalies-test-suite bundle exec rspec
```
