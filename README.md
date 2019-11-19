<p align="center">
    <h1 align="center">but</h1>
</p>

<p align="center">
    [b]ash [u]niversal [t]esting
</p>

## why?
I wanted to be able to test a number of different projects with a testing tool that provides 
simple installation, i.e. not a lot of dependencies or setup involved, portability, configurability, 
and the ability to test anything that exposes a shell interface.

## caveats
Due to its use of `gsed` and `gstat` on OS X (installed via homebrew), on any system that uses GNU sed or GNU stat
these programs should be aliased. `sed` should be aliased as `gsed` and `stat` should be aliased as `gstat`).

## getting started
`but` is written in Bash 5, but works in Bash 4 as well.

### dependencies
- Bash `>4`
- `gnu sed`
- `gnu stat`
- `jq`

```shell script
brew install bash gnu-sed gnu-stat jq
```

### using the `yarn` package manager

#### dependencies
- node `>=6`
- `npm`
- `yarn`

#### setup

Add (or update) an `.npmrc`:
```ini
@urzo:registry=https://npm.pkg.github.com
```
run this command to update your user npm configuration:
```shell script
echo "@urzo:registry=https://npm.pkg.github.com" >> ~/.npmrc
```
This allows the use of the GitHub package registry with `npm` and `yarn`.

#### installation
Using `yarn` symlinks `but` to /usr/local/bin/but which should *more than likely* be available in your `PATH`.
```bash
yarn global add @urzo/but
```

## concepts

### test
The atomic unit of `but` is the test. A test in `but` is a bash function that is prefixed with `test`.
The test name or description is derived from the function name so function names should be readable, 
descriptive, and delimited by an underscore (`_`).
The tests status, i.e. "passed" or "failed", is determined by examining the return code of the function, i.e.
a return code of 0 means the test has passed, and a non-zero return code means the test has failed.
*NOTE: test status can be negated with the test prefix `ntest` instead of the standard `test`.*

#### example
```shell script
test_should_pass() {
  return 0
}
```
or
```shell script
ntest_should_fail() {
  return 1
}
```

### suite
The molecular unit of `but` is the suite. A suite is a bash script that is:
- a non-executable
- contains no shebang
- has a file extension of `.but`
- contains 1 or more tests

In other words a `but` suite is just a file that contains functions that adhere to the conventions prescribed by `but`.

#### example
> `self.but`
```shell script
test_should_pass() {
  return 0
}
ntest_should_fail() {
  return 1
}
```

### suites
Suites in `but` are just a collection of bash scripts that contain bash functions. It must be a directory. The suites
directory may also contain the `.butrc` configuration.

#### example
```
$ tests/
       .butrc
       a.but
       b.but
```

## configuration
Configuring `but` requires a JSON configuration document with the name `.butrc`. 
A `.butrc` must have the `name`, and `root` keys. If the `but` command is run and a `BUT__CONFIG_SRC` environment variable
is present `but` will use the `.butrc` that the `BUT__CONFIG_SRC` environment variable points to, 
otherwise if the current working directory contains a `.butrc` it will use that `.butrc`.

In addition `but` provides the option to configure temporary files via the `tmp` key, and environment variables for all suites
via the `env` key.

**NOTE:  if a `.env` file is present in the directory `but` is run from it will source that `.env` file.

### example
> `.butrc`
```json
{
  "name": "my_tests",
  "tmp": {
    "A_TMP_FILE": "/tmp/a_tmp_file.txt"
  },
  "env": {
    "MY_ENV_VAR": "env_var_value"
  },
  "root": "/path/to/test/directory"
}
```

### `name`
> The name of the test suites.
> Injected into scripts as the  `BUT__INSTANCE_NAME` environment variable.

### `tmp`
> An object with values that point to temporary files created during tests.
> The keys are injected as environment variables, and the values are automatically removed when tests are completed.
> Use this configuration option when using temporary files in your tests. `but` will automatically cleanup those temp
> files.

#### example
> `.butrc`
```json
{
  "tmp": {
    "A_TMP_FILE": "/tmp/a_tmp_file.txt"
  }
}
```
> `test.but`
```shell script
test_should_have_tmp_file_with_specific_text() {
  echo "specific text" > "${A_TMP_FILE}"
  if [[ "$(< ${A_TMP_FILE})" == "specific text" ]]; then return 0; fi
}
```

### `env`
> An object whose key/value pairs are available as environment variables in all suites.

#### example
> `.butrc`
```json
{
  "env": {
    "MY_ENV_VAR": "env_var_value"
  }
}
```
> `test.but`
```shell script
test_should_have_environment_variale() {
  if [[ "${MY_ENV_VAR}" == "env_var_value" ]]; then return 0; fi
}
```

### `root`
> A path pointing to the directory of tests

## writing tests
Each test is defined by a bash function prefixed with `test` or `ntest`, and saved on disk as file
with the extension `.but`. Tests in a suite MUST NOT depend on each other as there is no guaranteed run order. 

### test file rules
1. MUST NOT be executable
2. MUST NOT have a shebang line
3. MUST contain at least one test function, i.e. bash function prefixes with `test` or `ntest`

### test function rules
1. MUST be prefixed with `test` or with `ntest`
2. MUST be delimited with an underscore `_`
3. SHOULD begin with `should`, e.g. `test_should_do_foo`
4. MUST execute at least 1 command
5. SHOULD NOT use `|| true`, this defeats the purpose
6. MUST NOT depend on other test functions

## lifecycle hooks
`but` supports running command hooks before and after each test suite, and before and after each test.

### before suite hook
`but` suites can define a function name `__before__`. This function is called before all tests in the suite.

#### example
```shell script
__before__() {
  echo "I run before all tests in this suite"
}
```

### after suite hook
`but` suites can define a function name `__after__`. This function is called after all in the suite.

### example
```shell script
__after__() {
    echo "I run after all tests in this suite"
}
```

### before each suite test hook
`but` test files can define a function name `__before_each__`. This function is called before each test.

### Example
```shell script
__before_each__() {
  echo "I run before each test in this suite"
}
```

### after each suite test hook
`but` test files can define a function name `__after_each__`. This function is called after each test.

### example
```shell script
__after_each__() {
  echo "I run after each test in this suite"
}
```

## usage
```shell script
yes | but
```

### order of operations
When the `but` command is called it:
1. Checks for the existence of a lockfile
2. Writes a lockfile if one does not exist
3. Validates the configuration file
4. Prepares the necessary test parameters from the configuration file
5. Prepares the tests
6. Execute the tests
7. Evaluate test output

### interactive
`but` is interactive and prompts for a `y` character to execute the tests. Use `yes | but` in automation or scripting.

### output
- TAP (default)
    - simplistic TAP output, does not support comments, directives, or YAML debug output.
    - `-t or --tap` flags if the `tap` npm module is installed `but` will pipe it's output through the `tap` program.
- JSON
    - output JSON documents for each test
    - `-j` or `--json` flags
- debug
    - disables tap and JSON output if used
    - very verbose debug output
    - `--verbose` flag

### example output
> `yes | but`
```shell script
TAP version 13
1..8
ok 1 Should fail
ok 2 Should have env vars
ok 3 Should have exact instance name
ok 4 Should have non empty instance name
ok 5 Should have non empty tmp file environment variables
ok 6 Should have run after hook
ok 7 Should have run before hook
ok 8 Should pass
Failed 0/8 tests, 100.00% okay
```

## license
Copyright 2019

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
