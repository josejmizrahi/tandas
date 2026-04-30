import 'server-only'
import { createClient } from '@/lib/supabase/server'

export async function getVote(voteId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('votes')
    .select('id, group_id, subject_type, subject_id, title, description, status, opens_at, closes_at, threshold, quorum, committee_only, result, created_by')
    .eq('id', voteId)
    .maybeSingle()
  if (error) throw error
  return data
}

export type VoteRow = NonNullable<Awaited<ReturnType<typeof getVote>>>

export async function getMyBallot(voteId: string, userId: string) {
  const supabase = await createClient()
  const { data, error } = await supabase
    .from('vote_ballots')
    .select('vote_id, user_id, choice, cast_at')
    .eq('vote_id', voteId)
    .eq('user_id', userId)
    .maybeSingle()
  if (error) throw error
  return data
}

export type VoteTally = {
  yes: number
  no: number
  abstain: number
  total: number
  eligible: number
  threshold: number
  quorum: number
}

export async function getVoteTally(voteId: string): Promise<VoteTally> {
  const supabase = await createClient()
  const [{ data: ballots }, { data: vote }] = await Promise.all([
    supabase.from('vote_ballots').select('choice').eq('vote_id', voteId),
    supabase.from('votes').select('group_id, threshold, quorum, committee_only').eq('id', voteId).single(),
  ])

  const counts = { yes: 0, no: 0, abstain: 0 }
  for (const b of ballots ?? []) {
    if (b.choice === 'yes' || b.choice === 'no' || b.choice === 'abstain') {
      counts[b.choice]++
    }
  }
  const total = counts.yes + counts.no + counts.abstain

  let eligible = 0
  if (vote) {
    const { count } = await supabase
      .from('group_members')
      .select('user_id', { count: 'exact', head: true })
      .eq('group_id', vote.group_id)
      .eq('active', true)
      .eq(vote.committee_only ? 'on_committee' : 'active', true)
    eligible = count ?? 0
  }

  return {
    ...counts,
    total,
    eligible,
    threshold: vote?.threshold ?? 0.5,
    quorum: vote?.quorum ?? 0.5,
  }
}

export type OpenVoteRow = {
  id: string
  subject_type: string
  subject_id: string | null
  title: string
  description: string | null
  closes_at: string
  status: string
}

export async function listOpenVotesForUser(groupId: string, userId: string): Promise<OpenVoteRow[]> {
  const supabase = await createClient()
  const { data: votes, error } = await supabase
    .from('votes')
    .select('id, subject_type, subject_id, title, description, closes_at, status, committee_only')
    .eq('group_id', groupId)
    .eq('status', 'open')
    .order('closes_at', { ascending: true })
  if (error) throw error
  if (!votes || votes.length === 0) return []

  // Filter out votes the user has already cast
  const voteIds = votes.map((v) => v.id)
  const { data: myBallots } = await supabase
    .from('vote_ballots')
    .select('vote_id')
    .in('vote_id', voteIds)
    .eq('user_id', userId)
  const voted = new Set((myBallots ?? []).map((b) => b.vote_id))

  return votes
    .filter((v) => !voted.has(v.id))
    .map((v) => ({
      id: v.id,
      subject_type: v.subject_type,
      subject_id: v.subject_id,
      title: v.title,
      description: v.description,
      closes_at: v.closes_at,
      status: v.status,
    }))
}
