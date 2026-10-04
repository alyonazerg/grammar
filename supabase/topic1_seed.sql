-- Grammar Course Hub · Topic 1 seed
-- Run once in Supabase SQL Editor after the core schema + submit_grammar_attempt function.

-- 1) Improve grading: arrays are compared as sets (order-independent).
create or replace function public.jsonb_answer_equal(a jsonb, b jsonb)
returns boolean
language sql
immutable
as $$
  select case
    when jsonb_typeof(a) = 'array' and jsonb_typeof(b) = 'array' then
      (select coalesce(jsonb_agg(x order by x::text), '[]'::jsonb) from jsonb_array_elements(a) x)
      =
      (select coalesce(jsonb_agg(x order by x::text), '[]'::jsonb) from jsonb_array_elements(b) x)
    else a = b
  end;
$$;

-- 2) Replace submission function to use order-independent grading.
create or replace function public.submit_grammar_attempt(
  p_full_name text,
  p_group_code text,
  p_assessment_id uuid,
  p_started_at timestamptz,
  p_answers jsonb,
  p_pair_cards jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid; v_attempt_id uuid; v_answer jsonb; v_pair jsonb;
  v_question_id uuid; v_question_points numeric; v_correct_answer jsonb;
  v_student_answer jsonb; v_is_correct boolean;
  v_score numeric := 0; v_max_score numeric := 0; v_percentage numeric := 0;
  v_clean_name text; v_clean_group text;
begin
  v_clean_name := trim(regexp_replace(p_full_name, '\s+', ' ', 'g'));
  v_clean_group := trim(p_group_code);
  if char_length(v_clean_name) < 3 or char_length(v_clean_name) > 100 then raise exception 'Invalid student name'; end if;
  if array_length(regexp_split_to_array(v_clean_name, '\s+'), 1) <> 2 then raise exception 'Please enter first name and surname, e.g. Ivan Ivanov'; end if;
  if v_clean_group not in ('150','151','154') then raise exception 'Invalid group'; end if;
  if not exists(select 1 from public.assessments where id=p_assessment_id and is_active=true) then raise exception 'Assessment is not available'; end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'array' then raise exception 'Invalid answers payload'; end if;

  select id into v_student_id from public.students where lower(full_name)=lower(v_clean_name) and group_code=v_clean_group limit 1;
  if v_student_id is null then
    insert into public.students(full_name,group_code) values(v_clean_name,v_clean_group) returning id into v_student_id;
  end if;

  insert into public.attempts(student_id,assessment_id,started_at,status)
  values(v_student_id,p_assessment_id,coalesce(p_started_at,now()),'in_progress') returning id into v_attempt_id;

  for v_answer in select value from jsonb_array_elements(p_answers) loop
    begin v_question_id := (v_answer->>'question_id')::uuid; exception when others then raise exception 'Invalid question ID'; end;
    select q.correct_answer,q.points into v_correct_answer,v_question_points
    from public.questions q where q.id=v_question_id and q.assessment_id=p_assessment_id;
    if not found then raise exception 'Question does not belong to this assessment'; end if;
    v_student_answer := v_answer->'answer';
    v_is_correct := public.jsonb_answer_equal(v_student_answer,v_correct_answer);
    insert into public.answers(attempt_id,question_id,student_answer,is_correct,points_awarded)
    values(v_attempt_id,v_question_id,v_student_answer,v_is_correct,case when v_is_correct then v_question_points else 0 end);
    v_max_score := v_max_score + v_question_points;
    if v_is_correct then v_score := v_score + v_question_points; end if;
  end loop;

  if p_pair_cards is not null and jsonb_typeof(p_pair_cards)='array' then
    for v_pair in select value from jsonb_array_elements(p_pair_cards) loop
      if coalesce(v_pair->>'code','')<>'' and coalesce(v_pair->>'prompt','')<>'' then
        insert into public.pair_checks(attempt_id,card_code,card_prompt)
        values(v_attempt_id,v_pair->>'code',v_pair->>'prompt');
      end if;
    end loop;
  end if;

  if v_max_score>0 then v_percentage:=round((v_score/v_max_score)*100,1); end if;
  update public.attempts set submitted_at=now(),score=v_score,max_score=v_max_score,percentage=v_percentage,status='submitted' where id=v_attempt_id;
  return jsonb_build_object('success',true,'attempt_id',v_attempt_id,'score',v_score,'max_score',v_max_score,'percentage',v_percentage);
end;
$$;

revoke all on function public.submit_grammar_attempt(text,text,uuid,timestamptz,jsonb,jsonb) from public;
grant execute on function public.submit_grammar_attempt(text,text,uuid,timestamptz,jsonb,jsonb) to anon, authenticated;

-- 3) Stable assessment lookup.
do $$
declare a uuid;
begin
  select ass.id into a from public.assessments ass join public.topics t on t.id=ass.topic_id
  where t.topic_number=1 and ass.title='Topic 1 Grammar Lab' limit 1;
  if a is null then raise exception 'Topic 1 Grammar Lab assessment not found'; end if;
  delete from public.question_skills where question_id in (select id from public.questions where assessment_id=a);
  delete from public.questions where assessment_id=a;

  -- Noun X-Ray / noun system
  insert into public.questions(assessment_id,question_order,question_type,prompt,options,correct_answer,explanation,textbook_reference,points) values
  (a,1,'multiple_choice','In “Her kindness surprised everyone”, select ALL correct descriptions of “kindness”.','["common noun","abstract noun","singular","common case","derivative noun","subject","material noun","genitive case"]','["common noun","abstract noun","singular","common case","derivative noun","subject"]','Kindness names an abstract quality; -ness forms a derivative noun. Here it is singular, in the common case, and functions as subject.','Kaushanskaya, Ch. I §§2–6',2),
  (a,2,'multiple_choice','In “The actress’s performance impressed us”, select ALL correct descriptions of “actress’s”.','["common noun","class noun","singular","genitive case","feminine","derivative noun","attribute","subject"]','["common noun","class noun","singular","genitive case","feminine","derivative noun","attribute"]','Actress denotes a person, is morphologically derived, and the genitive form functions attributively before performance.','Kaushanskaya, Ch. I §§3–7',2),
  (a,3,'multiple_choice','In “Fresh water is essential”, select ALL correct descriptions of “water”.','["common noun","noun of material","singular","common case","simple noun","subject","abstract noun","genitive case"]','["common noun","noun of material","singular","common case","simple noun","subject"]','Water is a common noun of material. In this sentence it is singular/common case and is the subject.','Kaushanskaya, Ch. I §§3–6',2),
  (a,4,'multiple_choice','In “The children’s playground was closed”, select ALL correct descriptions of “children’s”.','["common noun","class noun","plural","genitive case","simple noun","attribute","singular","common case"]','["common noun","class noun","plural","genitive case","simple noun","attribute"]','Children is an irregular plural; children’s is genitive and functions as an attribute to playground.','Kaushanskaya, Ch. I §§3–7',2),
  (a,5,'multiple_choice','In “My mother-in-law’s advice helped”, select ALL correct descriptions of “mother-in-law’s”.','["common noun","class noun","singular","genitive case","feminine","compound noun","attribute","simple noun"]','["common noun","class noun","singular","genitive case","feminine","compound noun","attribute"]','Mother-in-law is a compound noun; here its singular genitive form is an attribute.','Kaushanskaya, Ch. I §§3–7',2),
  (a,6,'single_choice','Choose the correct plural of mother-in-law.','["mother-in-laws","mothers-in-law","mothers-in-laws"]','"mothers-in-law"','In this compound, the principal noun mother takes the plural marker.','Kaushanskaya, Ch. I §6',1),
  (a,7,'single_choice','Choose the sentence with correct agreement.','["The news are surprising.","The news is surprising.","A news is surprising."]','"The news is surprising."','News has singular agreement despite its -s ending.','Kaushanskaya, Ch. I §6',1),

  -- Case / possession
  (a,8,'single_choice','Which description best fits John’s in “This book is John’s”?','["independent / absolute genitive","local use","of-phrase"]','"independent / absolute genitive"','The genitive stands independently: no following head noun is expressed.','Kaushanskaya, Ch. I §7',1),
  (a,9,'single_choice','In “My essay is longer than Daniel’s”, what is Daniel’s?','["elliptical use of the independent genitive","local use of the independent genitive","possessive determiner"]','"elliptical use of the independent genitive"','The repeated noun essay is understood from the context.','Kaushanskaya, Ch. I §7',1),
  (a,10,'single_choice','In “We are having dinner at Sarah’s”, what is Sarah’s?','["local use of the independent genitive","double genitive","possessive determiner"]','"local use of the independent genitive"','A place such as Sarah’s house/home is understood.','Kaushanskaya, Ch. I §7',1),
  (a,11,'single_choice','Which statement about “the car’s engine” and “the engine of the car” is best?','["Only the of-phrase is grammatical because car is inanimate.","Both can be grammatical; context, relation and information structure affect the choice.","Only the genitive is grammatical."]','"Both can be grammatical; context, relation and information structure affect the choice."','The animate/inanimate rule is only a tendency, not a grammatical ban. Inanimate nouns can occur naturally in the genitive.','Kaushanskaya, Ch. I §7; supplementary usage note',1),
  (a,12,'single_choice','Which is the strongly preferred everyday expression?','["yesterday’s meeting","the meeting of yesterday","both are equally neutral"]','"yesterday’s meeting"','Time expressions strongly favour the genitive.','Kaushanskaya, Ch. I §7',1),
  (a,13,'single_choice','In “my book”, what is my?','["possessive determiner (traditional: possessive adjective)","possessive pronoun","genitive noun"]','"possessive determiner (traditional: possessive adjective)"','Modern grammar calls my a possessive determiner because it occupies the determiner position before a noun; possessive adjective is the traditional label.','Terminology bridge',1),
  (a,14,'single_choice','Which sentence contains a double genitive?','["This is my father’s colleague.","This is a colleague of my father’s.","This is the colleague of my father."]','"This is a colleague of my father’s."','The post-genitive combines of with an independent possessive/genitive: a colleague of my father’s.','Supplementary usage note',1),
  (a,15,'single_choice','Which form is NOT standard for the intended double-genitive meaning?','["a friend of mine","that idea of Sarah’s","a friend of me"]','"a friend of me"','After of in this construction English uses an independent possessive form: mine, yours, his, hers, ours, theirs, or a noun genitive.','Supplementary usage note',1),

  -- Articles
  (a,16,'single_choice','___ coffee keeps me awake. Meaning: coffee as a substance/category in general.','["Ø","the","a"]','"Ø"','A noun of material in general reference normally has no article.','Kaushanskaya, Ch. II §§5–7',1),
  (a,17,'single_choice','Could I have ___ coffee, please? Meaning: one serving/cup.','["Ø","the","a"]','"a"','The material noun is recategorised as a countable serving.','Kaushanskaya, Ch. II §§5–7',1),
  (a,18,'single_choice','___ coffee you made is excellent.','["Ø","the","a"]','"the"','The clause you made identifies a particular quantity of coffee.','Kaushanskaya, Ch. II §§5–7',1),
  (a,19,'single_choice','___ kindness is important in a teacher. Meaning: the quality in general.','["Ø","the","a"]','"Ø"','An abstract noun used in general reference normally takes no article.','Kaushanskaya, Ch. II §§8–11',1),
  (a,20,'single_choice','She did me ___ kindness I will never forget. Meaning: one particular kind act.','["Ø","the","a"]','"a"','The abstract noun is used as a countable instance: one act of kindness.','Kaushanskaya, Ch. II §§8–11',1),
  (a,21,'single_choice','She went to ___ university at eighteen. Meaning: institution / its primary function.','["Ø","the","a"]','"Ø"','Institutional use has no article in this pattern.','Kaushanskaya, Ch. II §28',1),
  (a,22,'single_choice','I went to ___ university to meet my sister outside the library. Meaning: the particular place/building.','["Ø","the","a"]','"the"','Here university is a specific place rather than the institutional activity.','Kaushanskaya, Ch. II §28',1),
  (a,23,'single_choice','We had ___ breakfast at seven.','["Ø","the","a"]','"Ø"','Names of meals normally take no article in their basic use.','Kaushanskaya, Ch. II §30',1),
  (a,24,'single_choice','___ breakfast we had at the hotel was excellent.','["Ø","the","a"]','"the"','The breakfast is made definite by the identifying context.','Kaushanskaya, Ch. II §30',1),
  (a,25,'single_choice','Choose the standard form for the language name used generally.','["She speaks Ø English.","She speaks the English.","She speaks an English."]','"She speaks Ø English."','Names of languages normally take no article in this use.','Kaushanskaya, Ch. II §31',1),

  -- few/little/next
  (a,26,'single_choice','I have ___ close friends here, so I am not lonely.','["few","a few","the few"]','"a few"','A few means some: a small but meaningful number. Few emphasises insufficiency.','Kaushanskaya, Ch. II §33',1),
  (a,27,'single_choice','___ friends I have here are very supportive. Meaning: the small number that exists / is identified.','["few","a few","the few"]','"the few"','The few refers to the small identifiable set that exists.','Kaushanskaya, Ch. II §33',1),
  (a,28,'single_choice','There is ___ hope of success. The speaker means “almost no hope”.','["little","a little","the little"]','"little"','Little has a negative/insufficiency meaning: not much, almost none.','Kaushanskaya, Ch. II §33',1),
  (a,29,'single_choice','We still have ___ time, so let’s check the last answer. Meaning: some time remains.','["little","a little","the little"]','"a little"','A little means some, a small but usable amount.','Kaushanskaya, Ch. II §33',1),
  (a,30,'single_choice','I’ll finish it ___ week. Meaning: the calendar week after this one.','["next","the next","the following"]','"next"','Next week is deictic: it is calculated from the speaker’s present time.','Kaushanskaya, Ch. II §38',1),
  (a,31,'single_choice','He arrived on Monday and spent ___ week preparing for the exam.','["next","the next","a next"]','"the next"','The next week is a specific following one-week period measured from an established reference point.','Kaushanskaya, Ch. II §38',1),
  (a,32,'single_choice','Direct: “I’ll do it next week.” Choose the usual textbook reported-speech version.','["She said she would do it next week.","She said she would do it the following week.","She said she would do it a next week."]','"She said she would do it the following week."','Reported speech does not mechanically require the. The deictic centre changes; the following week is the usual textbook transformation.','Kaushanskaya, Ch. II §38; reported-speech usage note',1);

  -- Link questions to skills by ranges.
  insert into public.question_skills(question_id,skill_id)
  select q.id,s.id from public.questions q cross join public.skills s
  where q.assessment_id=a and (
    (q.question_order between 1 and 5 and s.skill_code in ('noun.classification','noun.composition','noun.number','noun.case')) or
    (q.question_order between 6 and 7 and s.skill_code='noun.number') or
    (q.question_order between 8 and 10 and s.skill_code in ('noun.case','noun.genitive','noun.genitive_independent')) or
    (q.question_order=10 and s.skill_code='noun.genitive_local') or
    (q.question_order between 11 and 12 and s.skill_code='possession.of_phrase') or
    (q.question_order=13 and s.skill_code='possession.pronouns') or
    (q.question_order between 14 and 15 and s.skill_code='possession.double_genitive') or
    (q.question_order between 16 and 18 and s.skill_code='article.material') or
    (q.question_order between 19 and 20 and s.skill_code='article.abstract') or
    (q.question_order between 21 and 25 and s.skill_code='article.special') or
    (q.question_order between 26 and 29 and s.skill_code='article.few_little') or
    (q.question_order between 30 and 32 and s.skill_code='article.next')
  );
end $$;

-- 4) Keep answer keys hidden before submission: anon can read prompts/options but not correct_answer.
-- Because table SELECT exposes whole rows, replace the broad questions policy with an RPC for public test content.
drop policy if exists "Public can read questions" on public.questions;

create or replace function public.get_active_assessment(p_topic_number integer)
returns table(
  assessment_id uuid,
  assessment_title text,
  question_id uuid,
  question_order integer,
  question_type text,
  prompt text,
  options jsonb,
  points numeric
)
language sql
security definer
set search_path=public
as $$
  select a.id,a.title,q.id,q.question_order,q.question_type,q.prompt,q.options,q.points
  from public.topics t
  join public.assessments a on a.topic_id=t.id and a.is_active=true
  join public.questions q on q.assessment_id=a.id
  where t.topic_number=p_topic_number and t.is_active=true
  order by q.question_order;
$$;
revoke all on function public.get_active_assessment(integer) from public;
grant execute on function public.get_active_assessment(integer) to anon, authenticated;

-- 5) Post-submit review: only answer-key content, no student data.
create or replace function public.get_assessment_review(p_assessment_id uuid)
returns table(question_id uuid, correct_answer jsonb, explanation text, textbook_reference text)
language sql
security definer
set search_path=public
as $$
  select q.id,q.correct_answer,q.explanation,q.textbook_reference
  from public.questions q
  join public.assessments a on a.id=q.assessment_id
  where q.assessment_id=p_assessment_id and a.is_active=true
  order by q.question_order;
$$;
revoke all on function public.get_assessment_review(uuid) from public;
grant execute on function public.get_assessment_review(uuid) to anon, authenticated;

select 'Topic 1 seed complete' as status,
       (select count(*) from public.questions q join public.assessments a on a.id=q.assessment_id join public.topics t on t.id=a.topic_id where t.topic_number=1) as questions;
