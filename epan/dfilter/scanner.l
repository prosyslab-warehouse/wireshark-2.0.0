%top {
/* Include this before everything else, for various large-file definitions */
#include "config.h"
#include <wireshark.h>

#include <stdlib.h>
#include <errno.h>

#include <wsutil/str_util.h>

#include "dfilter-int.h"
#include "syntax-tree.h"
#include "grammar.h"
#include "dfunctions.h"
}

/*
 * We want a reentrant scanner.
 */
%option reentrant

/*
 * We don't use input, so don't generate code for it.
 */
%option noinput

/*
 * We don't use unput, so don't generate code for it.
 */
%option nounput

/*
 * We don't read interactively from the terminal.
 */
%option never-interactive

/*
 * Prefix scanner routines with "df_" rather than "yy", so this scanner
 * can coexist with other scanners.
 */
%option prefix="df_"

/*
 * We're reading from a string, so we don't need yywrap.
 */
%option noyywrap

/*
 * The type for the state we keep for a scanner.
 */
%option extra-type="df_scanner_state_t *"

/*
 * We have to override the memory allocators so that we don't get
 * "unused argument" warnings from the yyscanner argument (which
 * we don't use, as we have a global memory allocator).
 *
 * We provide, as macros, our own versions of the routines generated by Flex,
 * which just call malloc()/realloc()/free() (as the Flex versions do),
 * discarding the extra argument.
 */
%option noyyalloc
%option noyyrealloc
%option noyyfree

%{
/*
 * Wireshark - Network traffic analyzer
 * By Gerald Combs <gerald@wireshark.org>
 * Copyright 2001 Gerald Combs
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

/*
 * Disable diagnostics in the code generated by Flex.
 */
DIAG_OFF_FLEX

stnode_t *df_lval;

static int set_lval_simple(df_scanner_state_t *state, int token, const char *token_value, sttype_id_t type_id);
#define simple(token)	(update_location(yyextra, yytext), set_lval_simple(yyextra, token, yytext, STTYPE_UNINITIALIZED))
#define test(token)	(update_location(yyextra, yytext), set_lval_simple(yyextra, token, yytext, STTYPE_TEST))
#define math(token)	(update_location(yyextra, yytext), set_lval_simple(yyextra, token, yytext, STTYPE_ARITHMETIC))

static int set_lval_literal(df_scanner_state_t *state, const char *token_value);
static int set_lval_unparsed(df_scanner_state_t *state, const char *token_value);
static int set_lval_quoted_string(df_scanner_state_t *state, GString *quoted_string);
static int set_lval_charconst(df_scanner_state_t *state, GString *quoted_string);
static int set_lval_field(df_scanner_state_t *state, const char *token_value);

static gboolean append_escaped_char(df_scanner_state_t *state, GString *str, char c);
static gboolean append_universal_character_name(df_scanner_state_t *state, GString *str, const char *ucn);
static gboolean parse_charconst(df_scanner_state_t *state, const char *s, unsigned long *valuep);

static void update_location(df_scanner_state_t *state, const char *text);
static void update_string_loc(df_scanner_state_t *state, const char *text);

#define FAIL(...) dfilter_fail(yyextra->dfw, &yyextra->location, __VA_ARGS__)

/*
 * Sleazy hack to suppress compiler warnings in yy_fatal_error().
 */
#define YY_EXIT_FAILURE ((void)yyscanner, 2)

/*
 * Macros for the allocators, to discard the extra argument.
 */
#define df_alloc(size, yyscanner)		(void *)malloc(size)
#define df_realloc(ptr, size, yyscanner)	(void *)realloc((char *)(ptr), (size))
#define df_free(ptr, yyscanner)			free((char *)ptr)

%}

Identifier	[[:alnum:]_][[:alnum:]_-]*(\.[[:alnum:]_-]+)*

hex2		[[:xdigit:]]{2}
MacAddress	{hex2}:{hex2}:{hex2}:{hex2}:{hex2}:{hex2}|{hex2}-{hex2}-{hex2}-{hex2}-{hex2}-{hex2}|{hex2}\.{hex2}\.{hex2}\.{hex2}\.{hex2}\.{hex2}

hex4		[[:xdigit:]]{4}
QuadMacAddress	{hex4}\.{hex4}\.{hex4}

dec-octet	[0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]
IPv4address	{dec-octet}\.{dec-octet}\.{dec-octet}\.{dec-octet}

h16		[0-9A-Fa-f]{1,4}
ls32		{h16}:{h16}|{IPv4address}
IPv6address	({h16}:){6}{ls32}|::({h16}:){5}{ls32}|({h16})?::({h16}:){4}{ls32}|(({h16}:){0,1}{h16})?::({h16}:){3}{ls32}|(({h16}:){0,2}{h16})?::({h16}:){2}{ls32}|(({h16}:){0,3}{h16})?::{h16}:{ls32}|(({h16}:){0,4}{h16})?::{ls32}|(({h16}:){0,5}{h16})?::{h16}|(({h16}:){0,6}{h16})?::

v4-cidr-prefix	\/[[:digit:]]{1,2}
v6-cidr-prefix	\/[[:digit:]]{1,3}

colon-bytes	{hex2}(:{hex2})+
dot-bytes	{hex2}(\.{hex2})+
hyphen-bytes	{hex2}(-{hex2})+

%x RANGE
%x LAYER
%x DQUOTE
%x SQUOTE
%x REFERENCE

%%

[[:blank:]\n]+	{
	update_location(yyextra, yytext);
}

"("		return simple(TOKEN_LPAREN);
")"		return simple(TOKEN_RPAREN);
","		return simple(TOKEN_COMMA);
"{"		return simple(TOKEN_LBRACE);
".."		return simple(TOKEN_DOTDOT);
"}"		return simple(TOKEN_RBRACE);
"$"		return simple(TOKEN_DOLLAR);
"any"		return simple(TOKEN_ANY);
"all"		return simple(TOKEN_ALL);

"=="		return test(TOKEN_TEST_ANY_EQ);
"eq"		return test(TOKEN_TEST_ANY_EQ);
"any_eq"	return test(TOKEN_TEST_ANY_EQ);
"!="		return test(TOKEN_TEST_ALL_NE);
"ne"		return test(TOKEN_TEST_ALL_NE);
"all_ne"	return test(TOKEN_TEST_ALL_NE);
"==="		return test(TOKEN_TEST_ALL_EQ);
"all_eq"	return test(TOKEN_TEST_ALL_EQ);
"!=="		return test(TOKEN_TEST_ANY_NE);
"~="		{
	add_deprecated_token(yyextra->dfw, "The operator \"~=\" is deprecated, use \"!==\" instead.");
	return test(TOKEN_TEST_ANY_NE);
}
"any_ne"	return test(TOKEN_TEST_ANY_NE);
">"		return test(TOKEN_TEST_GT);
"gt"		return test(TOKEN_TEST_GT);
">="		return test(TOKEN_TEST_GE);
"ge"		return test(TOKEN_TEST_GE);
"<"		return test(TOKEN_TEST_LT);
"lt"		return test(TOKEN_TEST_LT);
"<="		return test(TOKEN_TEST_LE);
"le"		return test(TOKEN_TEST_LE);
"contains"	return test(TOKEN_TEST_CONTAINS);
"~"		return test(TOKEN_TEST_MATCHES);
"matches"	return test(TOKEN_TEST_MATCHES);
"!"		return test(TOKEN_TEST_NOT);
"not"		return test(TOKEN_TEST_NOT);
"&&"		return test(TOKEN_TEST_AND);
"and"		return test(TOKEN_TEST_AND);
"||"		return test(TOKEN_TEST_OR);
"or"		return test(TOKEN_TEST_OR);
"in"		return test(TOKEN_TEST_IN);

"+"		return math(TOKEN_PLUS);
"-"		return math(TOKEN_MINUS);
"*"		return math(TOKEN_STAR);
"/"		return math(TOKEN_RSLASH);
"%"		return math(TOKEN_PERCENT);
"&"		return math(TOKEN_BITWISE_AND);
"bitwise_and"	return math(TOKEN_BITWISE_AND);

"#"				{
	BEGIN(LAYER);
	return simple(TOKEN_HASH);
}

<LAYER>[[:digit:]]+		{
	BEGIN(INITIAL);
	update_location(yyextra, yytext);
	return set_lval_simple(yyextra, TOKEN_INTEGER, yytext, STTYPE_UNINITIALIZED);
}

<LAYER>[^[:digit:][]			{
	update_location(yyextra, yytext);
	FAIL("Expected digit or \"[\", not \"%s\"", yytext);
	return SCAN_FAILED;
}

<INITIAL,LAYER>"["		{
	BEGIN(RANGE);
	return simple(TOKEN_LBRACKET);
}

<RANGE>[^],]+			{
	update_location(yyextra, yytext);
	return set_lval_simple(yyextra, TOKEN_RANGE_NODE, yytext, STTYPE_UNINITIALIZED);
}

<RANGE>","			{
	return simple(TOKEN_COMMA);
}

<RANGE>"]"				{
	BEGIN(INITIAL);
	return simple(TOKEN_RBRACKET);
}

<RANGE><<EOF>>				{
	update_location(yyextra, yytext);
	FAIL("The right bracket was missing from a slice.");
	return SCAN_FAILED;
}

[rR]{0,1}\042			{
	/* start quote of a quoted string */
	/*
	 * The example of how to scan for strings was taken from
	 * the flex manual, from the section "Start Conditions".
	 * See: https://westes.github.io/flex/manual/Start-Conditions.html
	 */
	BEGIN(DQUOTE);
	update_location(yyextra, yytext);
	yyextra->string_loc = yyextra->location;

	yyextra->quoted_string = g_string_new(NULL);

	if (yytext[0] == 'r' || yytext[0] == 'R') {
		/*
		 * This is a raw string (like in Python). Rules: 1) The two
		 * escape sequences are \\ and \". 2) Backslashes are
		 * preserved. 3) Double quotes in the string must be escaped.
		 * Corollary: Strings cannot end with an odd number of
		 * backslashes.
		 * Example: r"a\b\x12\"\\" is the string (including the implicit NUL terminator)
		 * {'a', '\\', 'b', '\\', 'x', '1', '2', '\\', '"', '\\'. '\\', '\0'}
		 */
		yyextra->raw_string = TRUE;
	}
	else {
		yyextra->raw_string = FALSE;
	}
}

<DQUOTE><<EOF>>				{
	/* unterminated string */
	update_string_loc(yyextra, yytext);
	g_string_free(yyextra->quoted_string, TRUE);
	yyextra->quoted_string = NULL;
	FAIL("The final quote was missing from a quoted string.");
	return SCAN_FAILED;
}

<DQUOTE>\042			{
	/* end quote */
	BEGIN(INITIAL);
	update_string_loc(yyextra, yytext);
	int token = set_lval_quoted_string(yyextra, yyextra->quoted_string);
	yyextra->quoted_string = NULL;
	yyextra->string_loc.col_start = -1;
	return token;
}

<DQUOTE>\\[0-7]{1,3} {
	/* octal sequence */
	update_string_loc(yyextra, yytext);
	if (yyextra->raw_string) {
		g_string_append(yyextra->quoted_string, yytext);
	}
	else {
		unsigned long result;
		result = strtoul(yytext + 1, NULL, 8);
		if (result > 0xff) {
			g_string_free(yyextra->quoted_string, TRUE);
			yyextra->quoted_string = NULL;
			FAIL("%s is larger than 255.", yytext);
			return SCAN_FAILED;
		}
		g_string_append_c(yyextra->quoted_string, (gchar) result);
	}
}

<DQUOTE>\\x[[:xdigit:]]{1,2} {
	/* hex sequence */
	/*
	 * C standard does not place a limit on the number of hex
	 * digits after \x... but we do. \xNN can have 1 or two Ns, not more.
	 */
	update_string_loc(yyextra, yytext);
	if (yyextra->raw_string) {
		g_string_append(yyextra->quoted_string, yytext);
	}
	else {
		unsigned long result;
		result = strtoul(yytext + 2, NULL, 16);
		g_string_append_c(yyextra->quoted_string, (gchar) result);
	}
}

<DQUOTE>\\u[[:xdigit:]]{0,4} {
	/* universal character name */
	update_string_loc(yyextra, yytext);
	if (yyextra->raw_string) {
		g_string_append(yyextra->quoted_string, yytext);
	}
	else if (!append_universal_character_name(yyextra, yyextra->quoted_string, yytext)) {
		g_string_free(yyextra->quoted_string, TRUE);
		yyextra->quoted_string = NULL;
		return SCAN_FAILED;
	}
}

<DQUOTE>\\U[[:xdigit:]]{0,8} {
	/* universal character name */
	update_string_loc(yyextra, yytext);
	if (yyextra->raw_string) {
		g_string_append(yyextra->quoted_string, yytext);
	}
	else if (!append_universal_character_name(yyextra, yyextra->quoted_string, yytext)) {
		g_string_free(yyextra->quoted_string, TRUE);
		yyextra->quoted_string = NULL;
		return SCAN_FAILED;
	}
}


<DQUOTE>\\.				{
	/* escaped character */
	update_string_loc(yyextra, yytext);
	if (yyextra->raw_string) {
		g_string_append(yyextra->quoted_string, yytext);
	}
	else if (!append_escaped_char(yyextra, yyextra->quoted_string, yytext[1])) {
		g_string_free(yyextra->quoted_string, TRUE);
		yyextra->quoted_string = NULL;
		return SCAN_FAILED;
	}
}

<DQUOTE>[^\\\042]+			{
	/* non-escaped string */
	update_string_loc(yyextra, yytext);
	g_string_append(yyextra->quoted_string, yytext);
}


\047				{
	/* start quote of a quoted character value */
	BEGIN(SQUOTE);
	update_location(yyextra, yytext);
	yyextra->string_loc = yyextra->location;

	yyextra->quoted_string = g_string_new("'");
}

<SQUOTE><<EOF>>				{
	/* unterminated character value */
	update_string_loc(yyextra, yytext);
	g_string_free(yyextra->quoted_string, TRUE);
	yyextra->quoted_string = NULL;
	FAIL("The final quote was missing from a character constant.");
	return SCAN_FAILED;
}

<SQUOTE>\047			{
	/* end quote */
	BEGIN(INITIAL);
	update_string_loc(yyextra, yytext);
	g_string_append_c(yyextra->quoted_string, '\'');
	int token = set_lval_charconst(yyextra, yyextra->quoted_string);
	yyextra->quoted_string = NULL;
	yyextra->string_loc.col_start = -1;
	return token;
}

<SQUOTE>\\.				{
	/* escaped character */
	update_string_loc(yyextra, yytext);
	g_string_append(yyextra->quoted_string, yytext);
}

<SQUOTE>[^\\\047]+			{
	/* non-escaped string */
	update_string_loc(yyextra, yytext);
	g_string_append(yyextra->quoted_string, yytext);
}


	/* None of the patterns below can match ".." anywhere in the token string. */

{MacAddress}|{QuadMacAddress}		{
	/* MAC Address. */
	update_location(yyextra, yytext);
	return set_lval_simple(yyextra, TOKEN_UNPARSED, yytext, STTYPE_UNINITIALIZED);
}

{IPv4address}{v4-cidr-prefix}?		{
	/* IPv4 with or without prefix. */
	update_location(yyextra, yytext);
	return set_lval_simple(yyextra, TOKEN_UNPARSED, yytext, STTYPE_UNINITIALIZED);
}

{IPv6address}{v6-cidr-prefix}?		{
	/* IPv6 with or without prefix. */
	update_location(yyextra, yytext);
	return set_lval_simple(yyextra, TOKEN_UNPARSED, yytext, STTYPE_UNINITIALIZED);
}

:?({colon-bytes}|{dot-bytes}|{hyphen-bytes})	{
	/* Bytes. */
	update_location(yyextra, yytext);
	if (yytext[0] == ':')
		return set_lval_literal(yyextra, yytext); /* Keep leading colon. */
	return set_lval_unparsed(yyextra, yytext);
}

:[[:xdigit:]]+		{
	/* Numeric. */
	update_location(yyextra, yytext);
	return set_lval_literal(yyextra, yytext); /* Keep leading colon. */
}

\.?{Identifier}			{
	/* Identifier or unparsed. */
	update_location(yyextra, yytext);
	if (yytext[0] == '.') {
		/* Skip leading dot. */
		return set_lval_field(yyextra, yytext + 1);
	}
	return set_lval_unparsed(yyextra, yytext);
}

. {
	/* Default */
	update_location(yyextra, yytext);
	if (isprint_string(yytext))
		FAIL("\"%s\" was unexpected in this context.", yytext);
	else
		FAIL("Non-printable ASCII characters may only appear inside double-quotes.");
	return SCAN_FAILED;
}


%%

/*
 * Turn diagnostics back on, so we check the code that we've written.
 */
DIAG_ON_FLEX

static void
_update_location(df_scanner_state_t *state, size_t len)
{
	state->location.col_start += (long)state->location.col_len;
	state->location.col_len = len;
}

static void
update_location(df_scanner_state_t *state, const char *text)
{
	_update_location(state, strlen(text));
}

static void
update_string_loc(df_scanner_state_t *state, const char *text)
{
	size_t len = strlen(text);
	state->string_loc.col_len += len;
	_update_location(state, len);
}

static int
set_lval_simple(df_scanner_state_t *state, int token, const char *token_value, sttype_id_t type_id)
{
	stnode_init(df_lval, type_id, NULL, g_strdup(token_value), &state->location);
	return token;
}

static int
set_lval_literal(df_scanner_state_t *state, const char *token_value)
{
	stnode_init(df_lval, STTYPE_LITERAL, g_strdup(token_value), g_strdup(token_value), &state->location);
	return TOKEN_LITERAL;
}

static int
set_lval_unparsed(df_scanner_state_t *state, const char *token_value)
{
	return set_lval_simple(state, TOKEN_UNPARSED, token_value, STTYPE_UNINITIALIZED);
}

static int
set_lval_quoted_string(df_scanner_state_t *state, GString *quoted_string)
{
	char *token_value;

	token_value = ws_escape_string_len(NULL, quoted_string->str, quoted_string->len, true);
	stnode_init(df_lval, STTYPE_STRING, quoted_string, token_value, &state->string_loc);
	return TOKEN_STRING;
}

static int
set_lval_charconst(df_scanner_state_t *state, GString *quoted_string)
{
	unsigned long number;
	gboolean ok;

	char *token_value = g_string_free(quoted_string, FALSE);
	ok = parse_charconst(state, token_value, &number);
	if (!ok) {
		g_free(token_value);
		return SCAN_FAILED;
	}
	stnode_init(df_lval, STTYPE_CHARCONST, g_memdup2(&number, sizeof(number)), token_value, &state->string_loc);
	return TOKEN_CHARCONST;
}

static int
set_lval_field(df_scanner_state_t *state, const char *token_value)
{
	header_field_info *hfinfo;

	hfinfo = dfilter_resolve_unparsed(state->dfw, token_value);
	if (hfinfo == NULL) {
		dfilter_fail(state->dfw, &state->location, "\"%s\" is not a valid protocol or protocol field.", token_value);
	}
	stnode_init(df_lval, STTYPE_FIELD, hfinfo, g_strdup(token_value), &state->location);
	return TOKEN_FIELD;
}

static gboolean
append_escaped_char(df_scanner_state_t *state, GString *str, char c)
{
	switch (c) {
		case 'a':
			c = '\a';
			break;
		case 'b':
			c = '\b';
			break;
		case 'f':
			c = '\f';
			break;
		case 'n':
			c = '\n';
			break;
		case 'r':
			c = '\r';
			break;
		case 't':
			c = '\t';
			break;
		case 'v':
			c = '\v';
			break;
		case '\\':
		case '\'':
		case '\"':
			break;
		default:
			dfilter_fail(state->dfw, &state->location,
					"\\%c is not a valid character escape sequence", c);
			return FALSE;
	}

	g_string_append_c(str, c);
	return TRUE;
}

static gboolean
parse_universal_character_name(df_scanner_state_t *state _U_, const char *str, char **ret_endptr, gunichar *valuep)
{
	guint64 val;
	char *endptr;
	int ndigits;

	if (str[0] != '\\')
		return FALSE;

	if (str[1] == 'u')
		ndigits = 4;
	else if (str[1] == 'U')
		ndigits = 8;
	else
		return FALSE;

	for (int i = 2; i < ndigits + 2; i++) {
		if (!g_ascii_isxdigit(str[i])) {
			return FALSE;
		}
	}

	errno = 0;
	val = g_ascii_strtoull(str + 2, &endptr, 16); /* skip leading 'u' or 'U' */

	if (errno != 0 || endptr == str || val > G_MAXUINT32) {
		return FALSE;
	}

	/*
	 * Ref: https://en.cppreference.com/w/c/language/escape
	 * Range of universal character names
	 *
	 * If a universal character name corresponds to a code point that is
	 * not 0x24 ($), 0x40 (@), nor 0x60 (`) and less than 0xA0, or a
	 * surrogate code point (the range 0xD800-0xDFFF, inclusive), or
	 * greater than 0x10FFFF, i.e. not a Unicode code point (since C23),
	 * the program is ill-formed. In other words, members of basic source
	 * character set and control characters (in ranges 0x0-0x1F and
	 * 0x7F-0x9F) cannot be expressed in universal character names.
	 */
	if (val < 0xA0 && val != 0x24 && val != 0x40 && val != 0x60)
		return FALSE;
	else if (val >= 0xD800 && val <= 0xDFFF)
		return FALSE;
	else if (val > 0x10FFFF)
		return FALSE;

	*valuep = (gunichar)val;
	if (ret_endptr)
		*ret_endptr = endptr;
	return TRUE;
}

static gboolean
append_universal_character_name(df_scanner_state_t *state, GString *str, const char *ucn)
{
	gunichar val;

	if (!parse_universal_character_name(state, ucn, NULL, &val)) {
		dfilter_fail(state->dfw, &state->location, "%s is not a valid universal character name", ucn);
		return FALSE;
	}

	g_string_append_unichar(str, val);
	return TRUE;
}

static gboolean
parse_charconst(df_scanner_state_t *state, const char *s, unsigned long *valuep)
{
	const char *cp;
	unsigned long value;
	gunichar unival;
	char *endptr;

	cp = s + 1;	/* skip the leading ' */
	if (*cp == '\'') {
		dfilter_fail(state->dfw, &state->string_loc, "Empty character constant.");
		return FALSE;
	}

	if (*cp == '\\') {
		/*
		 * C escape sequence.
		 * An escape sequence is an octal number \NNN,
		 * an hex number \xNN, or one of \' \" \\ \a \b \f \n \r \t \v
		 * that stands for the byte value of the equivalent
		 * C-escape in ASCII encoding.
		 */
		cp++;
		switch (*cp) {

		case '\0':
			dfilter_fail(state->dfw, &state->string_loc, "%s isn't a valid character constant.", s);
			return FALSE;

		case 'a':
			value = '\a';
			cp++;
			break;

		case 'b':
			value = '\b';
			cp++;
			break;

		case 'f':
			value = '\f';
			cp++;
			break;

		case 'n':
			value = '\n';
			break;

		case 'r':
			value = '\r';
			cp++;
			break;

		case 't':
			value = '\t';
			cp++;
			break;

		case 'v':
			value = '\v';
			cp++;
			break;

		case '\'':
			value = '\'';
			cp++;
			break;

		case '\\':
			value = '\\';
			cp++;
			break;

		case '"':
			value = '"';
			cp++;
			break;

		case 'x':
			cp++;
			if (*cp >= '0' && *cp <= '9')
				value = *cp - '0';
			else if (*cp >= 'A' && *cp <= 'F')
				value = 10 + (*cp - 'A');
			else if (*cp >= 'a' && *cp <= 'f')
				value = 10 + (*cp - 'a');
			else {
				dfilter_fail(state->dfw, &state->string_loc, "%s isn't a valid character constant.", s);
				return FALSE;
			}
			cp++;
			if (*cp != '\'') {
				value <<= 4;
				if (*cp >= '0' && *cp <= '9')
					value |= *cp - '0';
				else if (*cp >= 'A' && *cp <= 'F')
					value |= 10 + (*cp - 'A');
				else if (*cp >= 'a' && *cp <= 'f')
					value |= 10 + (*cp - 'a');
				else {
					dfilter_fail(state->dfw, &state->string_loc, "%s isn't a valid character constant.", s);
					return FALSE;
				}
			}
			cp++;
			break;

		case 'u':
		case 'U':
			if (!parse_universal_character_name(state, s+1, &endptr, &unival)) {
				dfilter_fail(state->dfw, &state->string_loc, "%s is not a valid universal character name", s);
				return FALSE;
			}
			value = (unsigned long)unival;
			cp = endptr;
			break;

		default:
			/* Octal */
			if (*cp >= '0' && *cp <= '7')
				value = *cp - '0';
			else {
				dfilter_fail(state->dfw, &state->string_loc, "%s isn't a valid character constant.", s);
				return FALSE;
			}
			if (*(cp + 1) != '\'') {
				cp++;
				value <<= 3;
				if (*cp >= '0' && *cp <= '7')
					value |= *cp - '0';
				else {
					dfilter_fail(state->dfw, &state->string_loc, "%s isn't a valid character constant.", s);
					return FALSE;
				}
				if (*(cp + 1) != '\'') {
					cp++;
					value <<= 3;
					if (*cp >= '0' && *cp <= '7')
						value |= *cp - '0';
					else {
						dfilter_fail(state->dfw, &state->string_loc, "%s isn't a valid character constant.", s);
						return FALSE;
					}
				}
			}
			if (value > 0xFF) {
				dfilter_fail(state->dfw, &state->string_loc, "%s is too large to be a valid character constant.", s);
				return FALSE;
			}
			cp++;
		}
	} else {
		value = *cp++;
		if (!g_ascii_isprint(value)) {
			dfilter_fail(state->dfw, &state->string_loc, "Non-printable value '0x%02lx' in character constant.", value);
			return FALSE;
		}
	}

	if ((*cp != '\'') || (*(cp + 1) != '\0')){
		dfilter_fail(state->dfw, &state->string_loc, "%s is too long to be a valid character constant.", s);
		return FALSE;
	}

	*valuep = value;
	return TRUE;
}