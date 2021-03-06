#!/usr/bin/env -S swipl -q --stack_limit=4m -g main

:- module(gcn, [main/1]).
:- autoload_path(library(http)).
:- use_module(library(persistency)).
:- use_module(library(xpath)).
:- (not(pack_info(smtp)) -> pack_install(smtp); true), use_module(library(smtp)).

:- persistent commitment(details).

:- dynamic action/2.

load_data(Data_dir) :-
   retractall(action(_,_)),
   swritef(Actions_glob,'%w/actions/*.pl', [Data_dir]),
   expand_file_name(Actions_glob,Action_files),
   maplist(load_files,Action_files),
   swritef(Config_file,'%w/config.pl', [Data_dir]),
   consult(Config_file),
   swritef(Db_file,'%w/signups.pl', [Data_dir]),
   db_attach(Db_file, []).

% load_sgml('data.example/actions/apples.xml',DOM,[]), xpath(DOM, //title(content), A).

:- http_handler(root(.),
	root_handler,[]).

:- http_handler(root(action),
	action_handler(Method),
	[method(Method), methods([get,post])]).

user:file_search_path(static, static).
:- http_handler(root(.), serve_files_in_directory(static), [prefix]).


root_handler(Request):-
	http_parameters(Request,[
		category(Category, [atom, optional(true)]),
		location(Location, [atom, optional(true)])
		]),
	action_list_page(Category,Location,Page),
	reply_gcn_page(Page).

reply_gcn_page(Page) :-
	reply_html_page([
	    title('Get Courage Now'),
	    \html_requires(root('gcn.css'))],
	  section([h1(a(href(/),'Get Courage Now')),Page])).

action_header(Id,Element) :-
	action(Id, Details),
	member(title(Title),Details),
	member(category(Category),Details),
	member(location(Location),Details),
	http_link_to_id(action_handler, [id(Id)], Action_link),
	http_link_to_id(root_handler, [category(Category)], Category_link),
	http_link_to_id(root_handler, [location(Location)], Location_link),
	action_progress(Id,Progress),
	Element = header(class(action),[
	h2(a(href(Action_link),Title)),
	div([
		span(class(location),a(href(Location_link),Location)), ' | ',
		span(class(category),a(href(Category_link),Category))]),
	Progress]).

action_body(Id,Element) :-
	action(Id,Details),
	member(description(Description),Details),
	action_signup_form(Id,Signup_form),
	action_share(Id,Share),
	Element = div([
		article(p(Description)),
		Share,
		Signup_form]).

action_share(Id,Element) :-
	site(Site),
	http_link_to_id(action_handler, [id(Id)], Action_link),
	action(Id,Details),
	member(title(Title),Details),
	swritef(Mailto_link,'mailto:?subject=%w&body=%w%w',[Title,Site,Action_link]),
	Element = p(class(share),a(href(Mailto_link), button('Invite friends to attend'))).

action_progress(Id,Element) :-
	action(Id,Details),
	member(target(Target),Details),
	action_commitments_count(Id, Signups_count),
	Element = div([
			small(label([Signups_count,' of ',Target,' commitments.'])),
			progress([max(Target), value(Signups_count)],[])]).

action_signup_form(Id,Element) :-
	Element = form([action(action),method(post)],fieldset([
		legend('Get involved'),
		input([name(action), type(hidden), value(Id)],[]),
		p(input([name(email), type(email), required(required), placeholder('my_name@example.com')],[])),
		p(button([class(ready),type(submit), name(ready), value(true)], 'I\'m ready, sign me up now')),
		details([summary('I\'m not ready yet'),
			ul([
			li('Which of the following would support you sufficiently to be ready?'),
			li(label([input([type(checkbox), name(support), value(childcare)]), 'I need free child care.'])),
			li(label([input([type(checkbox), name(support), value(transport)]), 'I need transport to and back.'])),
			li(label([input([type(checkbox), name(support), value(friend)]), 'I need to be invited by a friend.']))
			]),
			p(button([class(ready),type(submit), name(ready), value(true)], 'Sign me up'))])
		])).

category_location_actions(Category,Location,Action_list):-
	findall(List_item,
	  (action(Id,Details),
	   member(category(Category), Details),
	   member(location(Location), Details),
	   action_header(Id,Element),
	   List_item = li(Element)
	   ),
	  Action_list).

active_filter(Category,_Location,Filter):-
	ground(Category),
	Filter=p(['Category: ', Category]).

active_filter(_Category,Location,Filter):-
	ground(Location),
	Filter=p(['Location: ', Location]).

active_filter(_,_,p([])).

action_list_page(Category,Location,Page) :-
	active_filter(Category,Location,Filter),
	category_location_actions(Category,Location,List),
	Page = div([Filter,nav(ul(List))]).

action_handler(get, Request):-
	http_parameters(Request,[
		id(Action_id,[])]),
	signup_page(Action_id,Page),
	reply_gcn_page(Page).

action_handler(post, Request):-
	http_parameters(Request,[
		action(Id, [optional(false)]),
		email(Email, [length > 1]),
		ready(Ready, [length > 1]),
		support(Support, [list(atom)])
		]),
	get_time(Now),
	% check that action exists
	action(Id, _),
	% prevent duplicate signups
	(commitment(Details),
	 member(email(Email),Details),
	 member(id(Id),Details) ->
	   retract_commitment(Details); true),
	assert_commitment([id(Id), email(Email), time(Now), ready(Ready), support(Support)]),
	action_share(Id,Share),
	send_signup_confirmation_email(Email,Id),
	notify_everyone_if_ready(Id),
	http_link_to_id(action_handler, [id(Id)], Link),
	Page = div([
	  p('Thanks for signing up!'),
	  Share,
	  % Should show similar actions instead, perhaps
	  p(a(href(Link),'Return to action page.'))]),
	reply_gcn_page(Page).

action_commitments_count(Action_id, Commitments_count) :-
  findall(_Commitment, (commitment(Details), member(id(Action_id),Details)), Commitments),
  length(Commitments, Commitments_count).

target_reached(Action_id) :-
	action(Action_id, Details),
	member(target(Target), Details),
	action_commitments_count(Action_id, Commitments_count),
	% Commitments_count >= Target.
	% only send notification when the *exact* taget is reached
	Commitments_count = Target.

signup_page(Action_id,Page):-
	action_header(Action_id, Action_header),
	action_body(Action_id, Action_body),
	Page = section([
	Action_header,
	Action_body]).

action_ready_mail_text(Action_id, Out) :-
	action(Action_id, Details),
	member(description(Description), Details),
	format(Out, 'Ready for action. Enough people have signed up:,\n\n', []),
	format(Out, Description, []).

text_stream(Text, Out) :-
% just for sending emails
	format(Out, Text, []).

send_email(Email_to,Subject,Body) :-
	clause(email(_,_,_),_),
	email(smtp(SMTP),from(From),auth(Password)),
	thread_create(
		smtp_send_mail(
		  Email_to,
		  text_stream(Body),
		  [subject(Subject),
		   from(From),
		   smtp(SMTP),
		   auth(Password),
		   auth_method(login),
		   security(starttls)
		  ]),
		_Thread),!.

send_email(_,_,_) :-
% if email is not set up
  true.

send_signup_confirmation_email(Email_to,Action_id) :-
	Subject = 'Signed up',
	action(Action_id, Details),
	member(description(Description), Details),
	string_concat('You signed up for the following action: \n\n',Description,Text),
	send_email(Email_to,Subject,Text).

notify(Email_to,Action_id):-
	Subject = 'Action ready',
	action(Action_id, Details),
	member(description(Description), Details),
	string_concat('The target has been reached for following action: \n\n',Description,Text),
	send_email(Email_to,Subject,Text).

notify_everyone_if_ready(Action_id):-
	target_reached(Action_id),
	findall(
	  Email,
	  (commitment(Details),
	   member(id(Action_id),Details),
	   member(email(Email),Details),
	   notify(Email,Action_id)),
	  _Emails).

notify_everyone_if_ready(_Action_id):-
	true.

main(Argv):-
	argv_options(Argv, _RestArgv, Options),
	(member(port(Port),Options) -> true; Port=8080),
	% load data.example if there's no ./data
	(exists_directory(data) -> Data_dir='data'; Data_dir='data.example'),
	writef("Serving on :%w.\n", [Port]),
	load_data(Data_dir),
	http_server(http_dispatch, [port(Port)]).

